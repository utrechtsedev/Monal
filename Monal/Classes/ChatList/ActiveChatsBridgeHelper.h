//
//  ActiveChatsBridgeHelper.h
//  Monal
//
//  ObjC bridge for symbols not visible in Swift.
//  Add to bridging header: #import "ActiveChatsBridgeHelper.h"
//

#import <Foundation/Foundation.h>
#import <monalxmpp/MLContact.h>

NS_ASSUME_NONNULL_BEGIN

@interface ActiveChatsBridgeHelper : NSObject

/// Returns YES if the given xmpp accountState integer >= kStateInitStarted.
+ (BOOL)isAccountStateAtLeastInitStarted:(NSInteger)state;

/// Wraps MLXEPSlashMeHandler: returns /me display string or raw text.
+ (NSString*)displayStringForMessage:(NSString*)messageText inContact:(MLContact*)contact;

@end

NS_ASSUME_NONNULL_END
