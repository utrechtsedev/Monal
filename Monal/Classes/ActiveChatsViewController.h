//
//  ActiveChatsViewController.h
//  Monal
//
//  Created by Anurodh Pokharel on 6/14/13.
//
//  NOTE: Implementation is now in ActiveChatsView.swift.
//  The .m file should be REMOVED from the project.
//  The Swift class ActiveChatsHostingController is exposed to ObjC
//  as "ActiveChatsViewController" via @objc(ActiveChatsViewController).
//

#import <UIKit/UIKit.h>
#import <monalxmpp/MLConstants.h>
#import <monalxmpp/MLContact.h>
#import <monalxmpp/MLCall.h>

NS_ASSUME_NONNULL_BEGIN

@class chatViewController;
@class MLCall;

// SizeClassWrapper: implementation is in ActiveChatsView.swift.
// Forward-declared here for ObjC files that include this header.
@class SizeClassWrapper;

@interface ActiveChatsViewController : UIViewController

@property (nonatomic, strong) UITableView* _Nullable chatListTable;
@property (nonatomic, weak) IBOutlet UIBarButtonItem* settingsButton;
@property (nonatomic, weak) IBOutlet UIBarButtonItem* composeButton;
@property (nonatomic, strong) UIActivityIndicatorView* _Nullable spinner;
@property (nonatomic, strong) UILabel* _Nullable titleLabel;
@property (nonatomic, strong) UIView* _Nullable titleView;

@property (atomic, strong) SizeClassWrapper* sizeClass;
@property (atomic, readonly) UIViewController* _Nullable currentChatView;

-(void) showCallContactNotFoundAlert:(NSString*) jid;
-(void) callContact:(MLContact*) contact withUIKitSender:(_Nullable id) sender;
-(void) callContact:(MLContact*) contact withCallType:(MLCallType) callType;
-(void) presentAccountPickerForContacts:(NSArray<MLContact*>*) contacts andCallType:(MLCallType) callType;
-(void) presentCall:(MLCall*) call;
-(void) presentChatWithContact:(MLContact* _Nullable) contact;
-(void) presentChatWithContact:(MLContact* _Nullable) contact andCompletion:(monal_id_block_t _Nullable) completion;
-(void) presentSplitPlaceholder;
-(void) refreshDisplay;
-(void) showContacts;
-(void) deleteConversation;
-(void) showSettings;
-(void) showGeneralSettings;
-(void) prependGeneralSettings;
-(void) prependOneClickRegistration;
-(void) showNotificationSettings;
-(void) showDetails;
-(void) showRegisterWithUsername:(NSString*) username onHost:(NSString*) host withToken:(NSString* _Nullable) token usingCompletion:(monal_id_block_t _Nullable) callback;
-(void) showAddContactWithJid:(NSString*) jid preauthToken:(NSString* _Nullable) preauthToken prefillAccount:(xmpp* _Nullable) account andOmemoFingerprints:(NSDictionary* _Nullable) fingerprints;
-(void) showAddContact;
-(void) sheetDismissed;
-(void) segueToIntroScreensIfNeeded;
-(void) resetViewQueue;
-(void) dismissCompleteViewChainWithAnimation:(BOOL) animation andCompletion:(monal_void_block_t _Nullable) completion;
-(void) updateSizeClass;

-(void) segueToIntroScreensIfNeeded;
-(void) resetViewQueue;
-(void) dismissCompleteViewChainWithAnimation:(BOOL) animation andCompletion:(monal_void_block_t _Nullable) completion;
-(void) updateSizeClass;

@end

NS_ASSUME_NONNULL_END
