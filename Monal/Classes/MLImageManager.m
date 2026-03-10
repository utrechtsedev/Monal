//
//  MLImageManager.m
//  Monal
//
//  Created by Anurodh Pokharel on 8/16/13.
//
//

#import <monalxmpp/MLImageManager.h>
#import <monalxmpp/MLXMPPManager.h>
#import <monalxmpp/HelperTools.h>
#import <monalxmpp/DataLayer.h>
#import "AESGcm.h"
#import <monalxmpp/UIColor+Extension.h>


@interface MLImageManager()
@property (nonatomic, strong) NSCache* iconCache;
@property (nonatomic, strong) NSString* documentsDirectory;
@property (nonatomic, strong) NSCache* backgroundCache;
@end

@implementation MLImageManager

#pragma mark initilization

+(MLImageManager*) sharedInstance
{
    static dispatch_once_t once;
    static MLImageManager* sharedInstance;
    dispatch_once(&once, ^{
        DDLogVerbose(@"Creating shared image manager instance...");
        sharedInstance = [MLImageManager new];
    });
    return sharedInstance;
}

//this mehod should *only* be used in the mainapp due to memory requirements for large images
+(UIImage*) circularImage:(UIImage*) image
{
    return [[[UIGraphicsImageRenderer alloc] initWithSize:image.size] imageWithActions:^(UIGraphicsImageRendererContext* _Nonnull rendererContext) {
        UIBezierPath* clipPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
        [clipPath addClip];
        
        //Flip coordinates before drawing image as UIKit and CoreGraphics have inverted coordinate system
        CGContextTranslateCTM(rendererContext.CGContext, 0, image.size.height);
        CGContextScaleCTM(rendererContext.CGContext, 1, -1);
        
        CGContextDrawImage(rendererContext.CGContext, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
    }];
}

+(UIImage*) image:(UIImage*) image withMucOverlay:(UIImage*) overlay
{
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat new];
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    format.scale = 1.0;
    CGRect drawRect = CGRectMake(0, 0, image.size.width, image.size.height);
    CGFloat overlaySize = (float)(image.size.width / 3);
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:drawRect.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* _Nonnull context __unused) {
        [image drawInRect:drawRect];
        CGRect overlayRect = CGRectMake(0,                  //renderer.format.bounds.size.width - overlaySize
                                        0,                  //renderer.format.bounds.size.height - overlaySize
                                        overlaySize,
                                        overlaySize);
        [overlay drawInRect:overlayRect];
    }];
}

-(id) init
{
    self = [super init];
    self.iconCache = [NSCache new];
    self.backgroundCache = [NSCache new];
    
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    self.documentsDirectory = [[HelperTools getContainerURLForPathComponents:@[]] path];
    
    NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"imagecache"];
    [fileManager createDirectoryAtPath:writablePath withIntermediateDirectories:YES attributes:nil error:nil];
    [HelperTools configureFileProtectionFor:writablePath];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMemoryPressureNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    
    return self;
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) handleMemoryPressureNotification
{
    DDLogVerbose(@"Removing all objects in avatar cache due to memory pressure...");
    [self purgeCache];
}

#pragma mark cache

-(void) purgeCache
{
    [self.iconCache removeAllObjects];
    [self.backgroundCache removeAllObjects];
}

-(void) purgeCacheForContact:(NSString*) contact andAccount:(NSNumber*) accountID
{
    [self.iconCache removeObjectForKey:[NSString stringWithFormat:@"%@_%@", accountID, contact]];
    [self resetCachedBackgroundImageForContact:[MLContact createContactFromJid:contact andAccountID:accountID]];
}

-(void) cleanupHashes
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSArray<MLContact*>* contactList = [[DataLayer sharedInstance] contactList];
    
    for(MLContact* contact in contactList)
    {
        NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"buddyicons"];
        writablePath = [writablePath stringByAppendingPathComponent:contact.accountID.stringValue];
        writablePath = [writablePath stringByAppendingPathComponent:[self fileNameforContact:contact]];
        NSString* hash = [[DataLayer sharedInstance] getAvatarHashForContact:contact.contactJid andAccount:contact.accountID];
        BOOL hasHash = ![@"" isEqualToString:hash];
        
        if(hasHash && ![fileManager isReadableFileAtPath:writablePath])
        {
            DDLogDebug(@"Deleting orphan hash '%@' of contact: %@", hash, contact);
            //delete avatar hash from db if the file containing our image data vanished
            [[DataLayer sharedInstance] setAvatarHash:@"" forContact:contact.contactJid andAccount:contact.accountID];
        }
        
        if(!hasHash && [fileManager isReadableFileAtPath:writablePath])
        {
            DDLogDebug(@"Deleting orphan avatar file '%@' of contact: %@", writablePath, contact);
            NSError* error;
            [fileManager removeItemAtPath:writablePath error:&error];
            if(error)
                DDLogError(@"Error deleting orphan avatar file: %@", error);
        }
    }
}

-(void) removeAllIcons
{
    NSError* error;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"buddyicons"];
    [fileManager removeItemAtPath:writablePath error:&error];
    if(error)
        DDLogError(@"Got error while trying to delete all avatar files: %@", error);
}

#pragma mark chat bubbles

-(UIImage*) inboundImage
{
    if(_inboundImage)
        return _inboundImage;
    _inboundImage = [[UIImage imageNamed:@"incoming"] resizableImageWithCapInsets:UIEdgeInsetsMake(6, 6, 6, 6)];
    return _inboundImage;
    
}

-(UIImage*) outboundImage
{
    if (_outboundImage)
        return _outboundImage;
    _outboundImage = [[UIImage imageNamed:@"outgoing"] resizableImageWithCapInsets:UIEdgeInsetsMake(6, 6, 6, 6)];
    return _outboundImage;
}

#pragma mark user icons

-(UIImage*) generateDummyIconForContact:(MLContact*) contact
{
    return [self generateDummyIconForContact:contact withSymbol:@"person.fill"];
}

-(UIImage*) generateDummyIconForContact:(MLContact*) contact withSymbol:(NSString*) symbolName
{
    // Deterministically pick one of 4 colors from JID
    NSUInteger colorIndex = [contact.contactJid hash] % 4;
    BOOL isDarkMode = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    UIColor* background;
    UIColor* foreground;

    if(isDarkMode)
    {
        switch(colorIndex)
        {
            case 0: // Blue
                background = [UIColor colorWithRed:0.18 green:0.27 blue:0.40 alpha:1.0];
                foreground = [UIColor colorWithRed:0.55 green:0.68 blue:0.85 alpha:1.0];
                break;
            case 1: // Teal
                background = [UIColor colorWithRed:0.13 green:0.32 blue:0.28 alpha:1.0];
                foreground = [UIColor colorWithRed:0.48 green:0.72 blue:0.68 alpha:1.0];
                break;
            case 2: // Orange
                background = [UIColor colorWithRed:0.42 green:0.28 blue:0.15 alpha:1.0];
                foreground = [UIColor colorWithRed:0.85 green:0.65 blue:0.45 alpha:1.0];
                break;
            default: // Pink
                background = [UIColor colorWithRed:0.40 green:0.18 blue:0.27 alpha:1.0];
                foreground = [UIColor colorWithRed:0.85 green:0.55 blue:0.68 alpha:1.0];
                break;
        }
    }
    else
    {
        switch(colorIndex)
        {
            case 0: // Blue
                background = [UIColor colorWithRed:0.80 green:0.87 blue:0.96 alpha:1.0];
                foreground = [UIColor colorWithRed:0.30 green:0.47 blue:0.68 alpha:1.0];
                break;
            case 1: // Teal
                background = [UIColor colorWithRed:0.76 green:0.91 blue:0.87 alpha:1.0];
                foreground = [UIColor colorWithRed:0.22 green:0.52 blue:0.46 alpha:1.0];
                break;
            case 2: // Orange
                background = [UIColor colorWithRed:0.96 green:0.86 blue:0.76 alpha:1.0];
                foreground = [UIColor colorWithRed:0.72 green:0.46 blue:0.22 alpha:1.0];
                break;
            default: // Pink
                background = [UIColor colorWithRed:0.96 green:0.80 blue:0.87 alpha:1.0];
                foreground = [UIColor colorWithRed:0.68 green:0.30 blue:0.47 alpha:1.0];
                break;
        }
    }

    CGRect drawRect = CGRectMake(0, 0, 200, 200);
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:drawRect.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        //make sure our image is circular
        [[UIBezierPath bezierPathWithOvalInRect:drawRect] addClip];

        //fill the background of our image
        [background setFill];
        [context fillRect:renderer.format.bounds];

        //draw SF Symbol centered in our image
        UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:(drawRect.size.height / 2.0) weight:UIImageSymbolWeightRegular];
        UIImage* symbolImage = [[UIImage systemImageNamed:symbolName withConfiguration:config] imageWithTintColor:foreground renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize imageSize = symbolImage.size;
        CGRect imageRect = CGRectMake(floorf((float)(drawRect.size.width - imageSize.width) / 2),
                                      floorf((float)(drawRect.size.height - imageSize.height) / 2),
                                      imageSize.width,
                                      imageSize.height);
        [symbolImage drawInRect:imageRect];
    }];
}

-(NSString*) fileNameforContact:(MLContact*) contact
{
    return [NSString stringWithFormat:@"%@_%@.png", contact.accountID.stringValue, [contact.contactJid lowercaseString]];;
}

-(NSString*) fileNameforThumbnailOfMessage:(MLMessage*) message
{
    return [NSString stringWithFormat:@"%@.png", message.messageDBId.stringValue];
}

-(NSURL*) setThumbnailOfMessage:(MLMessage*) message withData:(NSData* _Nullable) data
{
    //documents directory/thumbnails/accountID/contact

    NSString* filename = [self fileNameforThumbnailOfMessage:message];

    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"thumbnails"];
    writablePath = [writablePath stringByAppendingPathComponent:message.accountID.stringValue];
    writablePath = [writablePath stringByAppendingPathComponent:message.buddyName];
    NSError* error;
    [fileManager createDirectoryAtPath:writablePath withIntermediateDirectories:YES attributes:nil error:&error];
    [HelperTools configureFileProtectionFor:writablePath];
    writablePath = [writablePath stringByAppendingPathComponent:filename];

    if([fileManager fileExistsAtPath:writablePath])
        [fileManager removeItemAtPath:writablePath error:nil];

    if(data)
    {
        if([data writeToFile:writablePath atomically:NO])
        {
            [HelperTools configureFileProtectionFor:writablePath];
            DDLogVerbose(@"wrote image to file: %@", writablePath);
            return [NSURL fileURLWithPath:writablePath];
        }
        else
            DDLogError(@"failed to write image to file: %@", writablePath);
    }
    return (NSURL*)nil;
}

-(void) setIconForContact:(MLContact*) contact WithData:(NSData* _Nullable) data
{
    //documents directory/buddyicons/account no/contact
    
    NSString* filename = [self fileNameforContact:contact];
    
    NSFileManager* fileManager = [NSFileManager defaultManager];
    
    NSString *writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"buddyicons"];
    writablePath = [writablePath stringByAppendingPathComponent:contact.accountID.stringValue];
    NSError* error;
    [fileManager createDirectoryAtPath:writablePath withIntermediateDirectories:YES attributes:nil error:&error];
    [HelperTools configureFileProtectionFor:writablePath];
    writablePath = [writablePath stringByAppendingPathComponent:filename];
    
    if([fileManager fileExistsAtPath:writablePath])
        [fileManager removeItemAtPath:writablePath error:nil];

    if(data)
    {
        if([data writeToFile:writablePath atomically:NO])
        {
            [HelperTools configureFileProtectionFor:writablePath];
            DDLogVerbose(@"wrote image to file: %@", writablePath);
        }
        else
            DDLogError(@"failed to write image to file: %@", writablePath);
    }
    
    //remove from cache if its there
    [self.iconCache removeObjectForKey:[NSString stringWithFormat:@"%@_%@", contact.accountID, contact]];
    
}

-(BOOL) hasIconForContact:(MLContact*) contact
{
    NSString* filename = [self fileNameforContact:contact];
    
    NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"buddyicons"];
    writablePath = [writablePath stringByAppendingPathComponent:contact.accountID.stringValue];
    writablePath = [writablePath stringByAppendingPathComponent:filename];
    
    DDLogVerbose(@"Checking avatar image at: %@", writablePath);
    return [UIImage imageWithContentsOfFile:writablePath] != nil;
}

-(NSURL*) getThumbnailURLOfMessage:(MLMessage*) message
{
    NSString* path = [self.documentsDirectory stringByAppendingPathComponent:@"thumbnails"];
    path = [path stringByAppendingPathComponent:message.accountID.stringValue];
    path = [path stringByAppendingPathComponent:message.buddyName];
    NSString* filename = [self fileNameforThumbnailOfMessage:message];
    path = [path stringByAppendingPathComponent:filename];
    if([[NSFileManager defaultManager] fileExistsAtPath:path])
        return [NSURL fileURLWithPath:path];
    else
        return nil;
}

-(UIImage*) getIconForContact:(MLContact*) contact
{
    return [self getIconForContact:contact withCompletion:nil];
}

-(UIImage*) getIconForContact:(MLContact*) contact withCompletion:(void (^)(UIImage *))completion
{
    NSString* filename = [self fileNameforContact:contact];
    
    __block UIImage* toreturn = nil;
    //get filname from DB
    NSString* appearanceSuffix = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    NSString* cacheKey = [NSString stringWithFormat:@"%@_%@_%@", contact.accountID, contact.contactJid, appearanceSuffix];
    
    //check cache
    toreturn = [self.iconCache objectForKey:cacheKey];
    if(!toreturn)
    {
        NSString* writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"buddyicons"];
        writablePath = [writablePath stringByAppendingPathComponent:contact.accountID.stringValue];
        writablePath = [writablePath stringByAppendingPathComponent:filename];
        
        DDLogVerbose(@"Loading avatar image at: %@", writablePath);
        UIImage* savedImage = [UIImage imageWithContentsOfFile:writablePath];
        if(savedImage)
            toreturn = savedImage;
        DDLogVerbose(@"Loaded image: %@", toreturn);
        
        if(toreturn == nil)             //return default avatar
        {
            DDLogVerbose(@"Using/generating dummy icon for contact: %@", contact);
            if(contact.isMuc)
                toreturn = [self generateDummyIconForContact:contact withSymbol:@"person.2.fill"];
            else
                toreturn = [self generateDummyIconForContact:contact];
        }
        
        //uiimage is cached if avaialable, but only if not in appex due to memory limits therein
        if(toreturn && ![HelperTools isAppExtension])
            [self.iconCache setObject:toreturn forKey:cacheKey];
        
        if(completion)
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(toreturn);
            });
    }
    else if(completion)
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(toreturn);
        });
    return toreturn;
}


-(void) saveBackgroundImageData:(NSData* _Nullable) data forContact:(MLContact* _Nullable) contact
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* writablePath;
    if(contact != nil)
    {
        NSString* filename = [self fileNameforContact:contact];
        writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"backgrounds"];
        
        [fileManager createDirectoryAtPath:writablePath withIntermediateDirectories:YES attributes:nil error:nil];
        [HelperTools configureFileProtectionFor:writablePath];
        
        writablePath = [writablePath stringByAppendingPathComponent:filename];
        if([fileManager fileExistsAtPath:writablePath])
            [fileManager removeItemAtPath:writablePath error:nil];
    }
    else
    {
        writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"background.jpg"];
        if([fileManager fileExistsAtPath:writablePath])
            [fileManager removeItemAtPath:writablePath error:nil];
    }
    [self resetCachedBackgroundImageForContact:contact];
    
    //file was deleted above, just don't create it again
    if(data != nil)
    {
        DDLogVerbose(@"Writing background image data %@ for %@ to '%@'...", data, contact, writablePath);
        [data writeToFile:writablePath atomically:YES];
        [HelperTools configureFileProtectionFor:writablePath];
    }
    
    //don't queue this notification because it should be handled immediately
    [[NSNotificationCenter defaultCenter] postNotificationName:kMonalBackgroundChanged object:contact];
}

-(UIImage* _Nullable) getBackgroundFor:(MLContact* _Nullable) contact
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* filename = @"background.jpg";
    if(contact != nil)
        filename = [self fileNameforContact:contact];
    UIImage* img = [self.backgroundCache objectForKey:filename];
    if(img != nil)
        return img;
    
    NSString* writablePath;
    if(contact != nil)
    {
        writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"backgrounds"];
        writablePath = [writablePath stringByAppendingPathComponent:filename];
        if(![fileManager fileExistsAtPath:writablePath])
            return nil;
    }
    else
    {
        writablePath = [self.documentsDirectory stringByAppendingPathComponent:@"background.jpg"];
        if(![fileManager fileExistsAtPath:writablePath])
            return nil;
    }
    DDLogVerbose(@"Loading background image for %@ from '%@'...", contact, writablePath);
    img = [UIImage imageWithContentsOfFile:writablePath];
    DDLogVerbose(@"Got image: %@", img);
    [self.backgroundCache setObject:img forKey:filename];
    return img;
}

-(void) resetCachedBackgroundImageForContact:(MLContact* _Nullable) contact
{
    NSString* filename = @"background.jpg";
    if(contact != nil)
        filename = [self fileNameforContact:contact];
    [self.backgroundCache removeObjectForKey:filename];
}

@end
