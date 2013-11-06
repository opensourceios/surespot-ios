//
//  IdentityController.m
//  surespot
//
//  Created by Adam on 6/8/13.
//  Copyright (c) 2013 2fours. All rights reserved.
//


#import "IdentityController.h"
#import "EncryptionController.h"
#import "NetworkController.h"
#import "FileController.h"
#import "SurespotIdentity.h"
#import "NSData+Gunzip.h"
#import "PublicKeys.h"
#include <zlib.h>
#import "CredentialCachingController.h"
#import "ChatController.h"

@interface IdentityController()
@property  (nonatomic, strong) SurespotIdentity * loggedInIdentity;
@end

@implementation IdentityController
+(IdentityController*)sharedInstance
{
    static IdentityController *sharedInstance = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

NSString *const CACHE_IDENTITY_ID = @"_cache_identity";
NSString *const EXPORT_IDENTITY_ID = @"_export_identity";
NSString *const IDENTITY_EXTENSION = @".ssi";


- (SurespotIdentity *) getIdentityWithUsername:(NSString *) username andPassword:(NSString *) password {
    SurespotIdentity * identity = [[CredentialCachingController sharedInstance] getIdentityWithUsername:username];
    if (!identity) {
        identity = [self loadIdentityUsername: (NSString *) username password:password];
    }
    return identity;
    
  }

-(SurespotIdentity *) loadIdentityUsername: (NSString * ) username password: (NSString *) password {
    
    NSString *filePath = [[[FileController getAppSupportDir] stringByAppendingPathComponent: username ] stringByAppendingString:IDENTITY_EXTENSION];
    NSData *myData = [NSData dataWithContentsOfFile:filePath];
    
    if (myData) {
        //gunzip the identity data
        //NSError* error = nil;
        NSData* unzipped = [myData gzipInflate];
        NSData * identity = [EncryptionController decryptIdentity: unzipped withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]];
        if (identity) {
            return [self decodeIdentityData:identity withUsername:username andPassword:password];
        }
    }
    
    return nil;

}

-(NSData *) encryptIdentity: (SurespotIdentity *) identity withPassword:(NSString *)password {
    NSMutableDictionary * dic = [NSMutableDictionary dictionaryWithObjectsAndKeys: [identity username] ,@"username", [identity salt], @"salt" ,nil];
    
    
    NSDictionary * identityKeys = [identity getKeys];
    NSMutableArray * encodedKeys = [[NSMutableArray alloc] init];
    NSEnumerator *enumerator = [identityKeys keyEnumerator];
    
    id key;
    while ((key = [enumerator nextObject])) {
        IdentityKeys *versionedKeys = [identityKeys objectForKey:key];
        NSDictionary *jsonKeys = [NSDictionary dictionaryWithObjectsAndKeys:
                                  [versionedKeys version] ,@"version",
                                  [EncryptionController encodeDHPrivateKey: [versionedKeys dhPrivKey]], @"dhPriv" ,
                                  [EncryptionController encodeDHPublicKey: [versionedKeys dhPubKey]], @"dhPub" ,
                                  [EncryptionController encodeDSAPrivateKey: [versionedKeys dsaPrivKey]], @"dsaPriv" ,
                                  [EncryptionController encodeDSAPublicKey: [versionedKeys dsaPubKey]], @"dsaPub" ,
                                  nil];
        
        [encodedKeys addObject:jsonKeys];
    }
    
    [dic setObject:encodedKeys forKey:@"keys"];
    NSError * error;
    NSData * jsonIdentity = [NSJSONSerialization dataWithJSONObject:dic options:kNilOptions error:&error];
    //  NSString * jsonString = [[NSString alloc] initWithData:jsonIdentity encoding:NSUTF8StringEncoding];
    return [EncryptionController encryptIdentity:jsonIdentity withPassword:password];
    
}

-( SurespotIdentity *) decodeIdentityData: (NSData *) identityData withUsername: (NSString *) username andPassword: (NSString *) password {
    try {
        NSError* error;
        
        NSDictionary* dic = [NSJSONSerialization JSONObjectWithData:identityData options:kNilOptions error:&error];
        
        //convert keys from json
        NSString * username = [dic objectForKey:@"username"];
        NSString * salt = [dic objectForKey:@"salt"];
        NSArray * keys = [dic objectForKey:@"keys"];
        
        SurespotIdentity * si = [[SurespotIdentity alloc] initWithUsername:username andSalt:salt];
        
        //
        for (NSDictionary * key in keys) {
            
            NSString * version = [key objectForKey:@"version"];
            //    NSString * dpubDH = [key objectForKey:@"dhPub"];
            NSString * dprivDH = [key objectForKey:@"dhPriv"];
            //   NSString * dsaPub = [key objectForKey:@"dsaPub"];
            NSString * dsaPriv = [key objectForKey:@"dsaPriv"];
            
            
            
            CryptoPP::DL_PrivateKey_EC<ECP>::DL_PrivateKey_EC dhPrivKey = [EncryptionController recreateDhPrivateKey:dprivDH];
            CryptoPP::ECDSA<ECP, CryptoPP::SHA256>::PrivateKey dsaPrivKey = [EncryptionController recreateDsaPrivateKey:dsaPriv];
            CryptoPP::DL_PublicKey_EC<ECP> dhPubKey;
            dhPrivKey.MakePublicKey(dhPubKey);
            
            CryptoPP::ECDSA<ECP, CryptoPP::SHA256>::PublicKey dsaPubKey;
            dsaPrivKey.MakePublicKey(dsaPubKey);
            
            [si addKeysWithVersion:version withDhPrivKey:dhPrivKey withDhPubKey:dhPubKey withDsaPrivKey:dsaPrivKey withDsaPubKey:dsaPubKey];
        }
        
        return si;
        
    } catch (const CryptoPP::Exception& e) {
        // cerr << e.what() << endl;
    }
    return nil;
    
}

-(void) setLoggedInUserIdentity: (SurespotIdentity *) identity {
    @synchronized (self) {
        self.loggedInIdentity = identity;
        [[ChatController sharedInstance] login];
        [[CredentialCachingController sharedInstance] loginIdentity:identity];
    }
}

- (void) createIdentityWithUsername: (NSString *) username
                        andPassword: (NSString *) password
                            andSalt: (NSString *) salt
                            andKeys: (IdentityKeys *) keys {
    
    
    SurespotIdentity * identity = [[SurespotIdentity alloc] initWithUsername:username andSalt:salt];
    [identity addKeysWithVersion:@"1" withDhPrivKey:[keys dhPrivKey] withDhPubKey:[keys dhPubKey] withDsaPrivKey:[keys dsaPrivKey] withDsaPubKey:[keys dsaPubKey] ];
    
    NSString * identityDir = [FileController getAppSupportDir];
    [self saveIdentity:identity toDir:identityDir withPassword:[password stringByAppendingString:CACHE_IDENTITY_ID]];
    [self setLoggedInUserIdentity:identity];
}



- (NSString *) saveIdentity: (SurespotIdentity *) identity toDir: (NSString *) identityDir withPassword: (NSString *) password {
    NSString * filename = [[identity username] stringByAppendingString:IDENTITY_EXTENSION];
    NSString * filePath = [identityDir stringByAppendingPathComponent:filename];
    
    
    NSData * encryptedCompressedIdentityData = [[self encryptIdentity:identity withPassword:password] gzipDeflate];
    
    [encryptedCompressedIdentityData writeToFile:filePath atomically:TRUE];
    return filePath;
}

- (NSArray *) getIdentityNames {
    NSString * identityDir = [FileController getAppSupportDir];
    NSArray * dirfiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:identityDir error:NULL];
    NSMutableArray * identityNames = [[NSMutableArray alloc] init];
    NSString * file;
    for (file in dirfiles) {
        NSString * extension = [file substringFromIndex:[file length] - [IDENTITY_EXTENSION length]];
        if ([extension isEqualToString:IDENTITY_EXTENSION]) {
            NSString * identityName = [file substringToIndex: [file length] - [IDENTITY_EXTENSION length]];
            [identityNames addObject: identityName ];
        }
    }
    return identityNames;
}

- (void) userLoggedInWithIdentity: (SurespotIdentity *) identity {
    [self setLoggedInUserIdentity:identity];
   }



- (NSString *) getLoggedInUser {
    return [[self getLoggedInIdentity] username];
}


- (SurespotIdentity *) getLoggedInIdentity {
    @synchronized (self) { return self.loggedInIdentity; }
}

- (NSString *) getOurLatestVersion {
    return [[self getLoggedInIdentity] latestVersion];
}

- (void) getTheirLatestVersionForUsername: (NSString *) username callback:(CallbackStringBlock) callback {
    NSLog(@"getTheirLatestVersionForUsername");
    
    [[NetworkController sharedInstance]
     getKeyVersionForUsername: username
     successBlock:^(AFHTTPRequestOperation *operation, id responseObject) {
         NSString * responseObjectS =   [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding];
         NSLog(@"getTheirLatestVersionForUsername response: %d, object: %@",  [operation.response statusCode], responseObjectS);
         callback(responseObjectS);
         
     }
     failureBlock:^(AFHTTPRequestOperation *operation, NSError *Error) {
         
         NSLog(@"response failure: %@",  Error);
         callback(nil);
         
     }];
    
    
    
    
}

-(void) getSharedSecretForOurVersion: (NSString *) ourVersion theirUsername: (NSString *) theirUsername theirVersion:( NSString *) theirVersion callback:(CallbackBlock) callback {
    [[CredentialCachingController sharedInstance] getSharedSecretForOurVersion:ourVersion theirUsername:theirUsername theirVersion:theirVersion callback:callback];
}

@end
