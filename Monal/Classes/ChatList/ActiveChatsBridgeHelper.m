//
//  ActiveChatsBridgeHelper.m
//  Monal
//
//  ObjC bridge implementation.
//
#import "ActiveChatsBridgeHelper.h"
#import <monalxmpp/xmpp.h>

@implementation ActiveChatsBridgeHelper

+ (BOOL)isAccountStateAtLeastInitStarted:(NSInteger)state
{
    return state >= kStateInitStarted;
}

+ (NSString*)displayStringForMessage:(NSString*)messageText inContact:(MLContact*)contact
{
    if(messageText.length > 4 && [messageText hasPrefix:@"/me "])
        return [NSString stringWithFormat:@"*%@ %@*", contact.contactDisplayName, [messageText substringFromIndex:4]];
    return messageText;
}

@end
