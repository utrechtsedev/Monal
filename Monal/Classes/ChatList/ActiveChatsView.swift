//
//  ActiveChatsView.swift
//  Monal
//
//  Translated from ActiveChatsViewController.m
//  Original by Anurodh Pokharel on 6/14/13.
//

import SwiftUI
import Combine
import monalxmpp

// MARK: - View ID
// File-private: NOT @objc — the original was a file-scoped typedef in the .m.
// Making it @objc caused "Redefinition of 'MLViewID'" when both files coexisted.

private enum ViewID: UInt {
    case unspecified = 0
    case registerView = 1
    case welcomeLoginView = 2
}

// MARK: - SizeClassWrapper
// Declared in the .h, implemented here.

@objc public class SizeClassWrapper: NSObject {
    @objc dynamic var horizontal: UIUserInterfaceSizeClass = .unspecified
}

// MARK: - View Queue Entry

private struct ViewQueueEntry {
    let id: ViewID
    // The block receives a resolver; calling resolver signals completion (mirrors PMKResolver).
    let block: (@escaping (Any?) -> Void) -> Void
    let file: String
    let line: Int
    let function: String
}

// MARK: - ActiveChatsCoordinator

/// Owns all coordination / presentation logic that was formerly in ActiveChatsViewController.
/// The hosting controller and SwiftUI view both reference this object.
class ActiveChatsCoordinator: NSObject, ObservableObject {

    // MARK: Published state for SwiftUI

    @Published var unpinnedContacts: [MLContact] = []
    @Published var pinnedContacts: [MLContact] = []
    @Published var searchText: String = ""

    // MARK: UIKit references (set by hosting controller)

    weak var hostingViewController: UIViewController?
    var settingsButton: UIBarButtonItem?
    var composeButton: UIBarButtonItem?
    var spinner: UIActivityIndicatorView?
    var titleLabel: UILabel?
    var titleView: UIView?
    var sizeClass = SizeClassWrapper()

    // Convenience accessors that mirror the ObjC property graph
    var navigationController: UINavigationController? { hostingViewController?.navigationController }

    // MARK: View queue internals

    // NSRecursiveLock because @synchronized(_blockQueue) in ObjC is reentrant;
    // the replace method can call prepend/append while already holding the lock.
    private var blockQueue: [ViewQueueEntry] = []
    private let blockQueueLock = NSRecursiveLock()
    private let blockQueueSemaphore = DispatchSemaphore(value: 1)

    // MARK: One-shot flags

    private var loginAlreadyAutodisplayed = false

    // MARK: Class-level warning dedup (static in ObjC via +(void)initialize)

    private static var mamWarningDisplayed = Set<NSNumber>()
    private static var smacksWarningDisplayed = Set<NSNumber>()
    private static var pushWarningDisplayed = Set<NSNumber>()

    // MARK: - Init / Deinit

    override init() {
        super.init()
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleRefreshDisplayNotification(_:)),
                       name: Notification.Name(kMonalRefresh), object: nil)
        nc.addObserver(self, selector: #selector(handleContactRemoved(_:)),
                       name: Notification.Name(kMonalContactRemoved), object: nil)
        nc.addObserver(self, selector: #selector(handleRefreshDisplayNotification(_:)),
                       name: Notification.Name(kMonalMessageFiletransferUpdateNotice), object: nil)
        nc.addObserver(self, selector: #selector(refreshContact(_:)),
                       name: Notification.Name(kMonalContactRefresh), object: nil)
        nc.addObserver(self, selector: #selector(handleNewMessage(_:)),
                       name: Notification.Name(kMonalNewMessageNotice), object: nil)
        nc.addObserver(self, selector: #selector(refreshContact(_:)),
                       name: Notification.Name(kMonalUpdatedMessageNotice), object: nil)
        nc.addObserver(self, selector: #selector(refreshContact(_:)),
                       name: Notification.Name(kMonalDeletedMessageNotice), object: nil)
        nc.addObserver(self, selector: #selector(messageSent(_:)),
                       name: Notification.Name(kMLMessageSentToContact), object: nil)
        nc.addObserver(self, selector: #selector(showWarningsIfNeeded),
                       name: Notification.Name(kMonalFinishedCatchup), object: nil)
    }

    // MARK: - View Queue Public API

    func resetViewQueue() {
        blockQueueLock.lock()
        blockQueue.removeAll()
        blockQueueLock.unlock()
    }

    /// Mirrors the single-arg `prependToViewQueue(block)` macro.
    private func prependToViewQueue(
        _ block: @escaping (@escaping (Any?) -> Void) -> Void,
        withId viewId: ViewID = .unspecified,
        file: String = #file, line: Int = #line, function: String = #function
    ) {
        let sanitizedFile = HelperTools.sanitizeFilePath(file)
        blockQueueLock.lock()
        DDLogDebug("Prepending block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) to queue...")
        let wrappedBlock: (@escaping (Any?) -> Void) -> Void = { resolve in
            DDLogDebug("Calling block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line)...")
            block(resolve)
            DDLogDebug("Block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) finished...")
        }
        blockQueue.insert(ViewQueueEntry(id: viewId, block: wrappedBlock, file: file, line: line, function: function), at: 0)
        blockQueueLock.unlock()
        processViewQueue()
    }

    /// Mirrors the single-arg `appendToViewQueue(block)` macro.
    private func appendToViewQueue(
        _ block: @escaping (@escaping (Any?) -> Void) -> Void,
        withId viewId: ViewID = .unspecified,
        file: String = #file, line: Int = #line, function: String = #function
    ) {
        let sanitizedFile = HelperTools.sanitizeFilePath(file)
        blockQueueLock.lock()
        DDLogDebug("Appending block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) to queue...")
        let wrappedBlock: (@escaping (Any?) -> Void) -> Void = { resolve in
            DDLogDebug("Calling block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line)...")
            block(resolve)
            DDLogDebug("Block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) finished...")
        }
        blockQueue.append(ViewQueueEntry(id: viewId, block: wrappedBlock, file: file, line: line, function: function))
        blockQueueLock.unlock()
        processViewQueue()
    }

    /// Mirrors `appendingReplaceOnViewQueue` / `prependingReplaceOnViewQueue`.
    private func replaceIdOnViewQueue(
        _ previousId: ViewID,
        withBlock block: @escaping (@escaping (Any?) -> Void) -> Void,
        havingId viewId: ViewID = .unspecified,
        appendOnUnknown: Bool,
        file: String = #file, line: Int = #line, function: String = #function
    ) {
        let sanitizedFile = HelperTools.sanitizeFilePath(file)
        blockQueueLock.lock()
        DDLogDebug("Replacing block with id \(previousId.rawValue) with new block having id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) to queue...")

        // Search for old block to replace and remove it
        var foundIndex: Int? = nil
        for (i, entry) in blockQueue.enumerated() {
            if entry.id == previousId {
                DDLogDebug("Found blockInfo at index \(i)")
                blockQueue.remove(at: i)
                foundIndex = i
                break
            }
        }

        if foundIndex == nil {
            // Lock is still held. The called method will re-acquire via NSRecursiveLock
            // (matching ObjC's reentrant @synchronized). We unlock our level after the call.
            if appendOnUnknown {
                DDLogDebug("Did not find block with id \(previousId.rawValue) on queue, appending block instead...")
                appendToViewQueue(block, withId: viewId, file: file, line: line, function: function)
            } else {
                DDLogDebug("Did not find block with id \(previousId.rawValue) on queue, prepending block instead...")
                prependToViewQueue(block, withId: viewId, file: file, line: line, function: function)
            }
            blockQueueLock.unlock()
            return
        }

        // Add replacement block at right position
        let wrappedBlock: (@escaping (Any?) -> Void) -> Void = { resolve in
            DDLogDebug("Calling block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line)...")
            block(resolve)
            DDLogDebug("Block with id \(viewId.rawValue) defined in \(function) at \(sanitizedFile):\(line) finished...")
        }
        let index = min(foundIndex!, blockQueue.count)
        blockQueue.insert(ViewQueueEntry(id: viewId, block: wrappedBlock, file: file, line: line, function: function), at: index)
        blockQueueLock.unlock()
        processViewQueue()
    }

    /// Mirrors `-(void) processViewQueue` — called on main queue, guarded by semaphore.
    private func processViewQueue() {
        HelperTools.dispatchAsync(true, reentrantOn: DispatchQueue.main) { [self] in
            let viewControllerHierarchy = self.getCurrentViewControllerHierarchy()

            // Don't show the next entry if there is still a previous one presented
            if viewControllerHierarchy.count > 0 {
                DDLogDebug("Ignoring call to processViewQueue, already showing: \(viewControllerHierarchy)")
                return
            }

            // Don't run the next block if the previous one did not yet complete
            if self.blockQueueSemaphore.wait(timeout: .now()) != .success {
                DDLogDebug("Ignoring call to processViewQueue, block still running, showing: \(viewControllerHierarchy)")
                return
            }

            self.blockQueueLock.lock()
            let entry: ViewQueueEntry?
            if !self.blockQueue.isEmpty {
                entry = self.blockQueue.removeFirst()
            } else {
                DDLogDebug("Queue is empty...")
                entry = nil
            }
            self.blockQueueLock.unlock()

            if let entry = entry {
                let looper = { [self] in
                    self.blockQueueSemaphore.signal()
                    DDLogDebug("Looping to next block...")
                    self.processViewQueue()
                }
                // Mirrors: AnyPromise(resolverBlock: { resolve in entry.block(resolve) }).ensure(looper)
                // The block receives `resolve`; when it calls resolve(nil), we loop.
                // `.ensure` fires on both resolve and reject. Since the block always
                // calls resolve(nil), this is equivalent.  If the block never calls
                // resolve the queue stalls — same as the ObjC version.
                entry.block { _ in looper() }
            } else {
                DDLogDebug("Not calling next block: there is none...")
                self.blockQueueSemaphore.signal()
            }
        }
    }

    // MARK: - Compose Button

    func configureComposeButton() {
        guard let btn = composeButton else { return }
        let hasContactRequests = DataLayer.sharedInstance().allContactRequests().count > 0
        if hasContactRequests {
            btn.image = HelperTools.imageWithNotificationBadge(for: UIImage(systemName: "plus")!)
            btn.accessibilityLabel = NSLocalizedString("Open contact list (contact requests pending)", comment: "")
        } else {
            btn.image = UIImage(systemName: "plus")
            btn.accessibilityLabel = NSLocalizedString("Open contact list", comment: "")
        }
        btn.target = self
        btn.action = #selector(showContactsAction(_:))
        btn.isAccessibilityElement = true
        btn.accessibilityTraits = .button
    }

    @objc private func showContactsAction(_ sender: Any) {
        showContacts()
    }

    // MARK: - Notification Handlers

    @objc private func handleRefreshDisplayNotification(_ notification: Notification) {
        // Filter notifications from within this class (mirrors ObjC's isKindOfClass check)
        if notification.object is ActiveChatsHostingController { return }
        refresh()
    }

    @objc private func handleContactRemoved(_ notification: Notification) {
        guard let removedContact = notification.userInfo?["contact"] as? MLContact else {
            unreachable()
        }
        DispatchQueue.main.async { [self] in
            DDLogInfo("Contact removed, refreshing active chats...")
            self.configureComposeButton()
            self.refreshDisplay()
            if let currentContact = MLNotificationManager.sharedInstance().currentContact,
               removedContact.isEqual(toContact: currentContact) {
                DDLogInfo("Contact removed, closing chat view...")
                self.presentChat(withContact: nil)
            }
        }
    }

    @objc private func messageSent(_ notification: Notification) {
        guard let contact = notification.userInfo?["contact"] as? MLContact else {
            unreachable()
        }
        insertOrMoveContact(contact, completion: nil)
    }

    @objc private func handleNewMessage(_ notification: Notification) {
        guard let newMessage = notification.userInfo?["message"] as? MLMessage,
              let contact = notification.userInfo?["contact"] as? MLContact,
              notification.object is xmpp else {
            unreachable()
        }
        if newMessage.messageType == kMessageTypeStatus { return }
        insertOrMoveContact(contact, completion: nil)
    }

    @objc private func refreshContact(_ notification: Notification) {
        guard let contact = notification.userInfo?["contact"] as? MLContact else { return }
        DDLogInfo("Refreshing contact \(contact.contactJid) at \(contact.accountID): unread=\(contact.unreadCount)")

        // Update red dot
        DispatchQueue.main.async { [self] in
            self.configureComposeButton()
        }

        // If pinning changed we have to move the user to another section
        if notification.userInfo?["pinningChanged"] != nil {
            insertOrMoveContact(contact, completion: nil)
        } else {
            DispatchQueue.main.async { [self] in
                // Find and reload the contact in our arrays
                if let idx = self.pinnedContacts.firstIndex(where: { $0.isEqual(toContact: contact) }) {
                    self.pinnedContacts[idx] = contact
                } else if let idx = self.unpinnedContacts.firstIndex(where: { $0.isEqual(toContact: contact) }) {
                    self.unpinnedContacts[idx] = contact
                }
            }
        }
    }

    // MARK: - Data Refresh

    func refreshDisplay() {
        HelperTools.dispatchAsync(true, reentrantOn: DispatchQueue.main) { [self] in
            let newUnpinned = (DataLayer.sharedInstance().activeContacts(withPinned: false) as? [MLContact]) ?? []
            let newPinned = (DataLayer.sharedInstance().activeContacts(withPinned: true) as? [MLContact]) ?? []

            // Make sure we don't display a chat view for a disabled account
            if let currentContact = MLNotificationManager.sharedInstance().currentContact {
                var found = false
                for item in DataLayer.sharedInstance().enabledAccountList() {
                    if let accountDict = item as? [String: Any],
                       let accountID = accountDict[kAccountID] as? NSNumber,
                       currentContact.accountID.intValue == accountID.intValue {
                        found = true
                    }
                }
                if !found {
                    self.presentChat(withContact: nil)
                }
            }

            self.unpinnedContacts = newUnpinned
            self.pinnedContacts = newPinned

            if let appDelegate = UIApplication.shared.delegate as? MonalAppDelegate {
                appDelegate.updateUnread()
            }
        }
    }

    func refresh() {
        HelperTools.dispatchAsync(true, reentrantOn: DispatchQueue.main) { [self] in
            self.refreshDisplay()
            self.processViewQueue()
        }
    }

    func sheetDismissed() {
        refresh()
    }

    // MARK: - Insert / Move Contact

    func insertOrMoveContact(_ contact: MLContact, completion: ((Bool) -> Void)?) {
        DispatchQueue.main.async { [self] in
            // Find existing position
            var existingSection: Int? = nil
            var existingRow: Int? = nil

            // Section 0 = pinned, Section 1 = unpinned (matches ObjC enum order)
            for section in 0..<2 {
                let arr = section == 0 ? self.pinnedContacts : self.unpinnedContacts
                if let idx = arr.firstIndex(where: { $0.isEqual(toContact: contact) }) {
                    existingSection = section
                    existingRow = idx
                    break
                }
            }

            let targetSection = contact.isPinned ? 0 : 1

            if let eSection = existingSection, let eRow = existingRow,
               eSection == targetSection && eRow == 0 {
                // Already at position 0 in the correct section — just replace
                DDLogVerbose("replacing already present contact '\(contact)' at section \(targetSection) row 0")
                if targetSection == 0 {
                    self.pinnedContacts[0] = contact
                } else {
                    self.unpinnedContacts[0] = contact
                }
                completion?(true)
                return
            }

            // Remove from old position if present
            if let eSection = existingSection, let eRow = existingRow {
                DDLogVerbose("moving already present contact...")
                if eSection == 0 {
                    self.pinnedContacts.remove(at: eRow)
                } else {
                    self.unpinnedContacts.remove(at: eRow)
                }
            }

            // Insert at top of target section
            let oldCount: Int
            if targetSection == 0 {
                oldCount = self.pinnedContacts.count
                self.pinnedContacts.insert(contact, at: 0)
            } else {
                oldCount = self.unpinnedContacts.count
                self.unpinnedContacts.insert(contact, at: 0)
            }

            // If this is a brand-new contact (wasn't in any array before), do a full refresh
            // to ensure the empty dataset disappears (mirrors ObjC logic)
            if existingSection == nil && oldCount == 0 {
                self.refreshDisplay()
            }

            completion?(true)
        }
    }

    // MARK: - Intro Screens

    func segueToIntroScreensIfNeeded() {
        DDLogDebug("segueToIntroScreensIfNeeded got called...")
        // Prepend in a prepend block to make sure we have prepended everything in order
        // before showing the first view.  Every entry in here is flipped, because we want
        // to prepend all intro screens to our queue.
        prependToViewQueue { [self] resolve in
            self.showWarningsIfNeeded()

            self.prependToViewQueue({ [self] resolve in
                // Display quick start if the user never seen it or if there are 0 enabled accounts
                if DataLayer.sharedInstance().enabledAccountCnts().intValue == 0
                    && !self.loginAlreadyAutodisplayed
                {
                    DDLogDebug("Showing WelcomeLogIn view...")
                    let loginVC = SwiftuiInterface().makeView(name: "WelcomeLogIn")
                    loginVC.ml_disposeCallback = { [self] in
                        self.loginAlreadyAutodisplayed = true
                        self.sheetDismissed()
                    }
                    self.dismissCompleteViewChain(withAnimation: false) { [self] in
                        self.presentVC(loginVC, animated: true) { resolve(nil) }
                    }
                } else {
                    resolve(nil)
                }
            }, withId: .welcomeLoginView)

            self.prependToViewQueue { [self] resolve in
                if !HelperTools.defaultsDB().bool(forKey: "hasCompletedOnboarding") {
                    DDLogDebug("Showing onboarding view...")
                    let view = SwiftuiInterface().makeView(name: "OnboardingView")
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        view.modalPresentationStyle = .fullScreen
                    } else {
                        view.ml_disposeCallback = { [self] in self.sheetDismissed() }
                    }
                    self.dismissCompleteViewChain(withAnimation: false) { [self] in
                        self.presentVC(view, animated: false) { resolve(nil) }
                    }
                } else {
                    resolve(nil)
                }
            }

            self.prependToViewQueue { [self] resolve in
                // Open password migration if needed
                let needingMigration = DataLayer.sharedInstance().accountListNeedingPasswordMigration()
                if needingMigration.count > 0 {
                    DDLogDebug("Showing password migration view...")
                    let passwordMigration = SwiftuiInterface().makePasswordMigration(needingMigration as! [[String: NSObject]])
                    passwordMigration.ml_disposeCallback = { [self] in self.sheetDismissed() }
                    self.dismissCompleteViewChain(withAnimation: false) { [self] in
                        self.presentVC(passwordMigration, animated: true) { resolve(nil) }
                    }
                } else {
                    resolve(nil)
                }
            }

            resolve(nil)
        }
    }

    // MARK: - Warnings

    @objc func showWarningsIfNeeded() {
        for item in DataLayer.sharedInstance().enabledAccountList() {
            guard let accountDict = item as? [String: Any],
                  let accountID = accountDict[kAccountID] as? NSNumber,
                  let account = MLXMPPManager.sharedInstance().getEnabledAccount(forID: accountID) else {
                continue
            }

            let stateInt = Int(account.accountState.rawValue)

            prependToViewQueue { [self] resolve in
                if !ActiveChatsCoordinator.mamWarningDisplayed.contains(accountID)
                    && ActiveChatsBridgeHelper.isAccountState(atLeastInitStarted: stateInt)
                    && account.connectionProperties.accountDiscoDone
                {
                    if !account.connectionProperties.accountDiscoFeatures.contains("urn:xmpp:mam:2") {
                        DDLogDebug("Showing MAM not supported warning...")
                        let alert = UIAlertController(
                            title: String(format: NSLocalizedString("Account %@", comment: ""), account.connectionProperties.identity.jid),
                            message: NSLocalizedString("Your server does not support MAM (XEP-0313). That means you could frequently miss incoming messages!! You should switch your server or talk to the server admin to enable this!", comment: ""),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel) { _ in
                            ActiveChatsCoordinator.mamWarningDisplayed.insert(accountID)
                            resolve(nil)
                        })
                        self.dismissCompleteViewChain(withAnimation: false) { [self] in
                            self.presentVC(alert, animated: true, completion: nil)
                        }
                    } else {
                        ActiveChatsCoordinator.mamWarningDisplayed.insert(accountID)
                        resolve(nil)
                    }
                } else {
                    resolve(nil)
                }
            }

            prependToViewQueue { [self] resolve in
                if !ActiveChatsCoordinator.smacksWarningDisplayed.contains(accountID)
                    && ActiveChatsBridgeHelper.isAccountState(atLeastInitStarted: stateInt)
                {
                    if !account.connectionProperties.supportsSM3 {
                        DDLogDebug("Showing smacks not supported warning...")
                        let alert = UIAlertController(
                            title: String(format: NSLocalizedString("Account %@", comment: ""), account.connectionProperties.identity.jid),
                            message: NSLocalizedString("Your server does not support Stream Management (XEP-0198). That means your outgoing messages can get lost frequently!! You should switch your server or talk to the server admin to enable this!", comment: ""),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel) { _ in
                            ActiveChatsCoordinator.smacksWarningDisplayed.insert(accountID)
                            resolve(nil)
                        })
                        self.dismissCompleteViewChain(withAnimation: false) { [self] in
                            self.presentVC(alert, animated: true, completion: nil)
                        }
                    } else {
                        ActiveChatsCoordinator.smacksWarningDisplayed.insert(accountID)
                        resolve(nil)
                    }
                } else {
                    resolve(nil)
                }
            }

            prependToViewQueue { [self] resolve in
                if !ActiveChatsCoordinator.pushWarningDisplayed.contains(accountID)
                    && ActiveChatsBridgeHelper.isAccountState(atLeastInitStarted: stateInt)
                    && account.connectionProperties.accountDiscoDone
                {
                    if !account.connectionProperties.accountDiscoFeatures.contains("urn:xmpp:push:0") {
                        DDLogDebug("Showing push not supported warning...")
                        let alert = UIAlertController(
                            title: String(format: NSLocalizedString("Account %@", comment: ""), account.connectionProperties.identity.jid),
                            message: NSLocalizedString("Your server does not support PUSH (XEP-0357). That means you have to manually open the app to retrieve new incoming messages!! You should switch your server or talk to the server admin to enable this!", comment: ""),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel) { _ in
                            ActiveChatsCoordinator.pushWarningDisplayed.insert(accountID)
                            resolve(nil)
                        })
                        self.dismissCompleteViewChain(withAnimation: false) { [self] in
                            self.presentVC(alert, animated: true, completion: nil)
                        }
                    } else {
                        ActiveChatsCoordinator.pushWarningDisplayed.insert(accountID)
                        resolve(nil)
                    }
                } else {
                    resolve(nil)
                }
            }
        }
    }

    // MARK: - Presentation Helpers

    private func presentVC(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        guard let host = hostingViewController else { completion?(); return }
        host.present(vc, animated: animated, completion: completion)
    }

    func presentSplitPlaceholder() {
        MLNotificationManager.sharedInstance().currentContact = nil
    }

    func showNotificationSettings() {
        dismissCompleteViewChain(withAnimation: false) { [self] in
            let view = SwiftuiInterface().makeView(name: "ActiveChatsNotificationSettings")
            view.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.presentVC(view, animated: true, completion: nil)
        }
    }

    func prependGeneralSettings() {
        prependToViewQueue { [self] resolve in
            let view = SwiftuiInterface().makeView(name: "ActiveChatsGeneralSettings")
            view.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(view, animated: true) { resolve(nil) }
            }
        }
    }

    func prependOneClickRegistration() {
        prependToViewQueue { [self] resolve in
            let view = SwiftuiInterface().makeView(name: "OneClickRegistration")
            view.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(view, animated: true) { resolve(nil) }
            }
        }
    }

    func showGeneralSettings() {
        appendToViewQueue { [self] resolve in
            let view = SwiftuiInterface().makeView(name: "ActiveChatsGeneralSettings")
            view.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(view, animated: true) { resolve(nil) }
            }
        }
    }

    func showSettings() {
        let view = SwiftuiInterface().makeView(name: "ActiveChatsSettings")
        view.ml_disposeCallback = { [self] in self.sheetDismissed() }
        dismissCompleteViewChain(withAnimation: false) { [self] in
            self.presentVC(view, animated: true) {
                NSLog("Settings presented successfully")
            }
        }
    }

    func markAllAsRead() {
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = DataLayer.sharedInstance().markAllUnreadMessagesAsRead()

            // Send display markers (XEP-0333/MDS) per contact
            for entry in entries {
                guard let contact = entry["contact"] as? MLContact,
                      let messages = entry["messages"] as? [MLMessage] else { continue }
                contact.account?.sendDisplayMarker(for: messages)
            }

            // Update UI and clear system notifications on main thread
            DispatchQueue.main.async {
                for entry in entries {
                    guard let contact = entry["contact"] as? MLContact,
                          let messages = entry["messages"] as? [MLMessage] else { continue }
                    // Clear system notifications and update app badge
                    MLNotificationQueue.current().post(
                        name: Notification.Name(kMonalDisplayedMessagesNotice),
                        object: contact.account,
                        userInfo: ["messagesArray": messages]
                    )
                    // Invalidate cached unreadCount on the singleton so next read re-queries DB
                    contact.updateUnreadCount()
                    // Trigger refreshContact() to replace contact in @Published arrays → SwiftUI re-render
                    MLNotificationQueue.current().post(
                        name: Notification.Name(kMonalContactRefresh),
                        object: contact.account,
                        userInfo: ["contact": contact]
                    )
                }
            }
        }
    }

    func showCallContactNotFoundAlert(_ jid: String) {
        let alert = UIAlertController(
            title: NSLocalizedString("Contact not found", comment: ""),
            message: String(format: NSLocalizedString("You tried to call contact '%@' but this contact could not be found in your contact list.", comment: ""), jid),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel, handler: nil))
        dismissCompleteViewChain(withAnimation: false) { [self] in
            self.presentVC(alert, animated: false, completion: nil)
        }
    }

    // MARK: - Calls

    func callContact(_ contact: MLContact, withCallType callType: MLCallType) {
        guard let appDelegate = UIApplication.shared.delegate as? MonalAppDelegate,
              let voipProcessor = appDelegate.voipProcessor else { return }
        if let activeCall = voipProcessor.getActiveCall(with: contact) {
            presentCall(activeCall)
        } else {
            presentCall(voipProcessor.initiateCall(with: callType, to: contact))
        }
    }

    func callContact(_ contact: MLContact, withUIKitSender sender: Any?) {
        guard let appDelegate = UIApplication.shared.delegate as? MonalAppDelegate,
              let voipProcessor = appDelegate.voipProcessor else { return }

        if let activeCall = voipProcessor.getActiveCall(with: contact) {
            presentCall(activeCall)
            return
        }

        let alert = UIAlertController(
            title: NSLocalizedString("Call Type", comment: ""),
            message: NSLocalizedString("What call do you want to place?", comment: ""),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("🎵 Audio", comment: ""), style: .default) { [self] _ in
            self.hostingViewController?.dismiss(animated: true)
            self.presentCall(voipProcessor.initiateCall(with: .audio, to: contact))
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("🎥 Video", comment: ""), style: .default) { [self] _ in
            self.hostingViewController?.dismiss(animated: true)
            self.presentCall(voipProcessor.initiateCall(with: .video, to: contact))
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { [self] _ in
            self.hostingViewController?.dismiss(animated: true)
        })

        if let popPresenter = alert.popoverPresentationController {
            if let barItem = sender as? UIBarButtonItem {
                popPresenter.barButtonItem = barItem
            } else {
                popPresenter.sourceView = hostingViewController?.view
            }
        }
        presentVC(alert, animated: true, completion: nil)
    }

    func presentAccountPicker(forContacts contacts: [MLContact], andCallType callType: MLCallType) {
        dismissCompleteViewChain(withAnimation: false) { [self] in
            let accountPicker = SwiftuiInterface().makeAccountPicker(for: contacts, and: callType.rawValue)
            accountPicker.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.presentVC(accountPicker, animated: true, completion: nil)
        }
    }

    func presentCall(_ call: MLCall) {
        dismissCompleteViewChain(withAnimation: false) { [self] in
            let callVC = SwiftuiInterface().makeCallScreen(for: call)
            callVC.modalPresentationStyle = .fullScreen
            self.presentVC(callVC, animated: false, completion: nil)
        }
    }

    // MARK: - Chat Presentation

    func presentChat(withContact contact: MLContact?) {
        presentChat(withContact: contact, andCompletion: nil)
    }

    func presentChat(withContact contact: MLContact?, andCompletion completion: monal_id_block_t?) {
        DDLogVerbose("presenting chat with contact: \(String(describing: contact)), stacktrace: \(Thread.callStackSymbols)")
        HelperTools.dispatchAsync(true, reentrantOn: DispatchQueue.main) { [self] in
            self.dismissCompleteViewChain(withAnimation: true) { [self] in
                // Only open contact chat when it is not opened yet
                if let contact = contact,
                   let currentContact = MLNotificationManager.sharedInstance().currentContact,
                   contact.isEqual(toContact: currentContact) {
                    MLNotificationQueue.current().post(name: Notification.Name(kMonalRefresh), object: nil, userInfo: nil)
                    completion?(true as NSObject)
                    return
                }

                // Clear old chat before opening a new one
                self.navigationController?.popViewController(animated: false)

                // Show placeholder if contact is nil, open chat otherwise
                guard let contact = contact else {
                    self.presentSplitPlaceholder()
                    completion?(false as NSObject)
                    return
                }

                // This will open the chat
                let presentator = { [self] in
                    let chatView = SwiftuiInterface().makeChatView(for: contact)
                    chatView.ml_disposeCallback = { [self] in self.sheetDismissed() }
                    self.scrollToContact(contact)
                    self.navigationController?.pushViewController(chatView, animated: true)
                }

                // Open chat — make sure we have an active buddy and add it to our UI if needed
                DataLayer.sharedInstance().addActiveBuddies(contact.contactJid, forAccount: contact.accountID)

                let inList = self.pinnedContacts.contains(where: { $0.isEqual(toContact: contact) })
                    || self.unpinnedContacts.contains(where: { $0.isEqual(toContact: contact) })

                if inList {
                    if HelperTools.defaultsDB().bool(forKey: "showNewChatView") {
                        presentator()
                    } else {
                        self.scrollToContact(contact)
                        self.hostingViewController?.performSegue(withIdentifier: "showConversation", sender: contact)
                    }
                    completion?(true as NSObject)
                } else {
                    self.insertOrMoveContact(contact) { [self] _ in
                        if HelperTools.defaultsDB().bool(forKey: "showNewChatView") {
                            presentator()
                        } else {
                            self.scrollToContact(contact)
                            self.hostingViewController?.performSegue(withIdentifier: "showConversation", sender: contact)
                        }
                        completion?(true as NSObject)
                    }
                }
            }
        }
    }

    // MARK: - Contacts

    func showAddContact(withJid jid: String, preauthToken: String?, prefillAccount account: xmpp?, andOmemoFingerprints fingerprints: NSDictionary?) {
        // Check if contact is already known in any of our accounts
        for item in MLXMPPManager.sharedInstance().connectedXMPP {
            guard let checkAccount = item as? xmpp else { continue }
            let checkContact = MLContact.createContact(fromJid: jid, andAccountID: checkAccount.accountID)
            if checkContact.isInRoster {
                presentChat(withContact: checkContact)
                return
            }
        }

        appendToViewQueue { [self] resolve in
            let addContactView = SwiftuiInterface().makeAddContactView(
                forJid: jid,
                preauthToken: preauthToken,
                prefillAccount: account,
                andOmemoFingerprints: fingerprints as? [NSNumber: Data],
                withDismisser: { [self] newContact in
                    self.presentChat(withContact: newContact)
                }
            )
            addContactView.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(addContactView, animated: false) { resolve(nil) }
            }
        }
    }

    func showAddContact() {
        appendToViewQueue { [self] resolve in
            let addContactView = SwiftuiInterface().makeAddContactView(
                dismisser: { [self] newContact in
                    self.presentChat(withContact: newContact)
                }
            )
            addContactView.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(addContactView, animated: false) { resolve(nil) }
            }
        }
    }

    func showContacts() {
        if showAccountNumberWarningIfNeeded() { return }

        appendToViewQueue { [self] resolve in
            let callback: (MLContact) -> Void = { [self] selectedContact in
                DDLogVerbose("Got selected contact from contactlist ui: \(selectedContact)")
                self.presentChat(withContact: selectedContact)
            }
            let contactsView = SwiftuiInterface().makeContactsView(dismisser: callback, button: self.composeButton)
            self.presentVC(contactsView, animated: true) { resolve(nil) }
        }
    }

    func showRegister(withUsername username: String, onHost host: String, withToken token: String?, usingCompletion callback: monal_id_block_t?) {
        replaceIdOnViewQueue(.welcomeLoginView, withBlock: { [self] resolve in
            // Build dict mirroring ObjC's nilWrapper()/nilDefault() macros:
            // nilWrapper wraps nil → NSNull; nilDefault provides a fallback.
            var dict: [String: AnyObject] = [
                "host": (host as NSString),
                "username": (username as NSString),
            ]
            dict["token"] = (token as NSString?) ?? (NSNull() as AnyObject)
            let comp: monal_id_block_t = callback ?? { accountID in
                DDLogWarn("Dummy reg completion called for accountID: \(String(describing: accountID))")
            }
            dict["completion"] = comp as AnyObject

            let registerVC = SwiftuiInterface().makeAccountRegistration(dict)
            registerVC.ml_disposeCallback = { [self] in self.sheetDismissed() }
            self.dismissCompleteViewChain(withAnimation: false) { [self] in
                self.presentVC(registerVC, animated: true) { resolve(nil) }
            }
        }, havingId: .registerView, appendOnUnknown: false)
    }

    func showDetails() {
        appendToViewQueue { [self] resolve in
            if let currentContact = MLNotificationManager.sharedInstance().currentContact {
                let detailsVC = SwiftuiInterface().makeContactDetails(currentContact)
                detailsVC.ml_disposeCallback = { [self] in self.sheetDismissed() }
                self.dismissCompleteViewChain(withAnimation: false) { [self] in
                    self.presentVC(detailsVC, animated: true) { resolve(nil) }
                }
            } else {
                resolve(nil)
            }
        }
    }

    func deleteConversation() {
        for section in 0..<2 {
            let arr = section == 0 ? pinnedContacts : unpinnedContacts
            for (idx, rowContact) in arr.enumerated() {
                if let currentContact = MLNotificationManager.sharedInstance().currentContact,
                   rowContact.isEqual(toContact: currentContact) {
                    if section == 0 {
                        pinnedContacts.remove(at: idx)
                    } else {
                        unpinnedContacts.remove(at: idx)
                    }
                    DataLayer.sharedInstance().removeActiveBuddy(rowContact.contactJid, forAccount: rowContact.accountID)
                    refreshDisplay()
                    presentChat(withContact: nil)
                    return
                }
            }
        }
    }

    // MARK: - Account Warning

    @discardableResult
    func showAccountNumberWarningIfNeeded() -> Bool {
        if DataLayer.sharedInstance().enabledAccountCnts().intValue == 0 {
            let alert = UIAlertController(
                title: NSLocalizedString("No enabled account found", comment: ""),
                message: NSLocalizedString("Please add a new account under settings first. If you already added your account you may need to enable it under settings", comment: ""),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .default) { _ in
                alert.dismiss(animated: true)
            })
            presentVC(alert, animated: true, completion: nil)
            return true
        }
        return false
    }

    // MARK: - View Controller Hierarchy / Dismissal

    func getCurrentViewControllerHierarchy() -> [UIViewController] {
        guard let appDelegate = UIApplication.shared.delegate as? MonalAppDelegate,
              var root = appDelegate.window?.rootViewController else { return [] }
        var viewControllers: [UIViewController] = []
        while let presented = root.presentedViewController {
            viewControllers.append(presented)
            root = presented
        }
        return viewControllers.reversed()
    }

    func dismissCompleteViewChain(withAnimation animation: Bool, andCompletion completion: (() -> Void)?) {
        let viewControllers = getCurrentViewControllerHierarchy()
        DDLogVerbose("Dismissing view controller hierarchy: \(viewControllers)")
        dismissRecursor(viewControllers, animation: animation, completion: completion)
    }

    private func dismissRecursor(_ viewControllers: [UIViewController], animation: Bool, completion: (() -> Void)?) {
        guard let first = viewControllers.first else {
            DDLogVerbose("View chain completely dismissed...")
            completion?()
            return
        }
        let remaining = Array(viewControllers.dropFirst())
        DDLogVerbose("Dismissing: \(first)")
        first.dismiss(animated: animation) { [self] in
            self.dismissRecursor(remaining, animation: animation, completion: completion)
        }
    }

    // MARK: - Scroll / Selection

    func scrollToContact(_ contact: MLContact) {
        // In SwiftUI this is handled by the view's selection binding.
        // No-op for UITableView-less architecture.
        // (The ObjC version called selectRowAtIndexPath on chatListTable.)
    }

    func updateSizeClass() {
        if let host = hostingViewController {
            sizeClass.horizontal = host.view.traitCollection.horizontalSizeClass
        }
    }

    var currentChatView: UIViewController? {
        guard !HelperTools.defaultsDB().bool(forKey: "showNewChatView") else { return nil }
        guard let controllers = navigationController?.viewControllers,
              controllers.count > 1,
              NSStringFromClass(type(of: controllers[1])) == "chatViewController" else {
            return nil
        }
        return controllers[1]
    }

    /// Convenience accessor for SwiftUI view.
    func getChatArray(forSection section: Int) -> [MLContact] {
        section == 0 ? pinnedContacts : unpinnedContacts
    }
}

// MARK: - SwiftUI View

struct ActiveChatsView: View {
    @ObservedObject var coordinator: ActiveChatsCoordinator

    private var filteredPinnedContacts: [MLContact] {
        if coordinator.searchText.isEmpty { return coordinator.pinnedContacts }
        return coordinator.pinnedContacts.filter { searchMatchesContact(contact: $0, search: coordinator.searchText) }
    }

    private var filteredUnpinnedContacts: [MLContact] {
        if coordinator.searchText.isEmpty { return coordinator.unpinnedContacts }
        return coordinator.unpinnedContacts.filter { searchMatchesContact(contact: $0, search: coordinator.searchText) }
    }

    private func searchMatchesContact(contact: MLContact, search: String) -> Bool {
        let jid = contact.contactJid.lowercased()
        let name = contact.contactDisplayName.lowercased()
        let search = search.lowercased()
        return jid.contains(search) || name.contains(search)
    }

    var body: some View {
        Group {
            if coordinator.pinnedContacts.isEmpty && coordinator.unpinnedContacts.isEmpty {
                emptyView
            } else {
                chatList
            }
        }
    }

    private var chatList: some View {
        List {
            if !filteredPinnedContacts.isEmpty {
                Section {
                    ForEach(Array(filteredPinnedContacts.enumerated()), id: \.element) { index, contact in
                        chatRow(contact, isFirst: index == 0)
                    }
                }
            }
            Section {
                ForEach(Array(filteredUnpinnedContacts.enumerated()), id: \.element) { index, contact in
                    chatRow(contact, isFirst: index == 0 && filteredPinnedContacts.isEmpty)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 60)
    }

    private func chatRow(_ contact: MLContact, isFirst: Bool = false) -> some View {
        let lastMessage = DataLayer.sharedInstance().lastMessage(forContact: contact.contactJid, forAccount: contact.accountID)
        let isSelected: Bool = {
            guard let currentContact = MLNotificationManager.sharedInstance().currentContact else { return false }
            return contact.isEqual(toContact: currentContact)
        }()

        return ContactCellView(contact: contact, lastMessage: lastMessage)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparatorTint(Color(UIColor.separator))
            .alignmentGuide(.listRowSeparatorTrailing) { d in d[.trailing] }
            .listRowSeparator(isFirst ? .hidden : .automatic, edges: .top)
            .frame(height: 60)
            .background(isSelected ? Color(UIColor.lightGray) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                coordinator.presentChat(withContact: contact)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    archiveChat(contact)
                } label: {
                    Text(NSLocalizedString("Archive chat", comment: ""))
                }
            }
    }

    private func archiveChat(_ contact: MLContact) {
        if let i = coordinator.pinnedContacts.firstIndex(where: { $0.isEqual(toContact: contact) }) {
            coordinator.pinnedContacts.remove(at: i)
        } else if let i = coordinator.unpinnedContacts.firstIndex(where: { $0.isEqual(toContact: contact) }) {
            coordinator.unpinnedContacts.remove(at: i)
        }
        DataLayer.sharedInstance().removeActiveBuddy(contact.contactJid, forAccount: contact.accountID)
        coordinator.refreshDisplay()
        coordinator.presentChat(withContact: nil)
    }

    private var emptyView: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(UITraitCollection.current.userInterfaceStyle == .dark ? "chat_dark" : "chat")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200)
            Spacer()
                .frame(height: 32)
            Text(NSLocalizedString("No active conversations", comment: ""))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(UITraitCollection.current.userInterfaceStyle == .dark ? .white : .black)
            Spacer()
                .frame(height: 16)
            Text(NSLocalizedString("When you start a conversation\nwith someone, they will\nshow up here.", comment: ""))
                .font(.system(size: 14))
                .foregroundColor(UITraitCollection.current.userInterfaceStyle == .dark ? .white : .black)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("chats"))
    }
}

// MARK: - Contact Cell View

struct ContactCellView: View {
    @StateObject var contact: ObservableKVOWrapper<MLContact>
    let lastMessage: MLMessage?

    init(contact: MLContact, lastMessage: MLMessage?) {
        _contact = StateObject(wrappedValue: ObservableKVOWrapper<MLContact>(contact))
        self.lastMessage = lastMessage
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: MLImageManager.sharedInstance().getIconFor(contact.obj) ?? UIImage())
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(contact.contactDisplayName as String? ?? "")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let timestamp = lastMessage?.timestamp {
                        Text(formatTimestamp(timestamp))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    messageText
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if (contact.unreadCount as NSNumber?)?.intValue ?? 0 > 0 {
                        Text("\((contact.unreadCount as NSNumber?)?.intValue ?? 0)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var messageText: some View {
        if let msg = lastMessage, !msg.messageText.isEmpty {
            Text(ActiveChatsBridgeHelper.displayString(forMessage: msg.messageText, in: contact.obj))
        } else {
            Text("")
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return NSLocalizedString("Yesterday", comment: "")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}

// MARK: - Hosting Controller

/// UIViewController that hosts the SwiftUI ActiveChatsView and exposes the full
/// ObjC-compatible API that the rest of the app expects from "ActiveChatsViewController".
/// The @objc(ActiveChatsViewController) attribute makes ObjC see this class under the
/// original name, satisfying the @class forward declaration in MonalAppDelegate.h.
@objc(ActiveChatsViewController)
class ActiveChatsHostingController: UIViewController, UISearchResultsUpdating {

    let coordinator = ActiveChatsCoordinator()
    private var hostingController: UIHostingController<ActiveChatsView>!

    // MARK: Properties forwarded from the coordinator (match .h declarations)

    @objc var settingsButton: UIBarButtonItem? {
        get { coordinator.settingsButton }
        set { coordinator.settingsButton = newValue }
    }
    @objc var composeButton: UIBarButtonItem? {
        get { coordinator.composeButton }
        set { coordinator.composeButton = newValue }
    }
    @objc var sizeClass: SizeClassWrapper {
        get { coordinator.sizeClass }
        set { coordinator.sizeClass = newValue }
    }
    @objc var spinner: UIActivityIndicatorView? {
        get { coordinator.spinner }
        set { coordinator.spinner = newValue }
    }
    @objc var titleLabel: UILabel? {
        get { coordinator.titleLabel }
        set { coordinator.titleLabel = newValue }
    }
    @objc var titleView: UIView? {
        get { coordinator.titleView }
        set { coordinator.titleView = newValue }
    }
    @objc var currentChatView: UIViewController? { coordinator.currentChatView }

    // chatListTable: kept for storyboard/ObjC compatibility but not used by SwiftUI rendering.
    @objc var chatListTable: UITableView?

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        DDLogDebug("active chats view did load")
        super.viewDidLoad()

        coordinator.hostingViewController = self

        view.backgroundColor = .lightGray
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Wire up app delegate.
        // Swift's static type system sees ActiveChatsViewController (from ObjC @class) as
        // separate from ActiveChatsHostingController despite @objc(ActiveChatsViewController).
        // Use performSelector to bypass the type mismatch.
        if let appDelegate = UIApplication.shared.delegate as? MonalAppDelegate {
            appDelegate.perform(NSSelectorFromString("setActiveChats:"), with: self)
            let check = appDelegate.perform(NSSelectorFromString("activeChats"))
            DDLogInfo("ActiveChatsHostingController viewDidLoad: activeChats set, value=\(String(describing: check))")
        } else {
            DDLogError("ActiveChatsHostingController viewDidLoad: MonalAppDelegate cast FAILED")
        }

        // Embed SwiftUI
        hostingController = UIHostingController(rootView: ActiveChatsView(coordinator: coordinator))
        addChild(hostingController)
        hostingController.view.frame = view.bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        coordinator.sizeClass = SizeClassWrapper()
        coordinator.updateSizeClass()

        // Set up ellipsis menu
        let markAllReadAction = UIAction(
            title: NSLocalizedString("Mark all as read", comment: ""),
            image: UIImage(systemName: "envelope.open")
        ) { [weak self] _ in
            self?.coordinator.markAllAsRead()
        }

        let menu = UIMenu(children: [markAllReadAction])
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: menu
        )

        coordinator.configureComposeButton()

        // Create title view with spinner and label (mirrors ObjC viewDidLoad)
        let containerView = UIView()

        let activitySpinner = UIActivityIndicatorView(style: .medium)
        activitySpinner.hidesWhenStopped = true
        activitySpinner.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(activitySpinner)
        coordinator.spinner = activitySpinner

        let label = UILabel()
        label.text = NSLocalizedString("Chats", comment: "")
        label.font = .boldSystemFont(ofSize: 17)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(label)
        coordinator.titleLabel = label
        coordinator.titleView = containerView

        NSLayoutConstraint.activate([
            activitySpinner.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            activitySpinner.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: activitySpinner.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            label.topAnchor.constraint(equalTo: containerView.topAnchor),
            label.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        navigationItem.titleView = containerView

        // Search controller
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = NSLocalizedString("Search chats", comment: "")
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        definesPresentationContext = true

        coordinator.refresh()

        // Has to be done here to not always prepend intro screens onto our view queue
        // once a fullscreen view is dismissed (or the app is switched to foreground)
        coordinator.segueToIntroScreensIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        DDLogDebug("active chats view will appear")
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        DDLogDebug("active chats view did appear")
        super.viewDidAppear(animated)
        coordinator.refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        DDLogDebug("active chats view will disappear")
        super.viewWillDisappear(animated)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        self.coordinator.updateSizeClass()
    }

    // MARK: - UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        coordinator.searchText = searchController.searchBar.text ?? ""
    }

    // MARK: - Segues

    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {
        return true
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        DDLogInfo("Got segue identifier '\(segue.identifier ?? "")'")

        if segue.identifier == "showConversation" {
            if let chatVC = segue.destination as? UIViewController,
               let contact = sender as? MLContact {
                navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
                // chatViewController is an ObjC class; call setupWithContact: via selector
                // to avoid requiring it in the bridging header.
                let sel = NSSelectorFromString("setupWithContact:")
                if chatVC.responds(to: sel) {
                    chatVC.perform(sel, with: contact)
                }
            }
        }

        if segue.identifier == "showDetails" {
            if let contact = sender as? MLContact {
                let detailsVC = SwiftuiInterface().makeContactDetails(contact)
                detailsVC.ml_disposeCallback = { [weak self] in self?.coordinator.sheetDismissed() }
                present(detailsVC, animated: true)
            }
        }
    }

    // MARK: - @objc Forwarding
    // Every public method declared in the .h is forwarded to the coordinator.

    @objc func showCallContactNotFoundAlert(_ jid: String) { coordinator.showCallContactNotFoundAlert(jid) }
    @objc func callContact(_ contact: MLContact, withUIKitSender sender: Any?) { coordinator.callContact(contact, withUIKitSender: sender) }
    @objc func callContact(_ contact: MLContact, withCallType callType: MLCallType) { coordinator.callContact(contact, withCallType: callType) }
    @objc func presentAccountPicker(forContacts contacts: [MLContact], andCallType callType: MLCallType) { coordinator.presentAccountPicker(forContacts: contacts, andCallType: callType) }
    @objc func presentCall(_ call: MLCall) { coordinator.presentCall(call) }
    @objc func presentChat(withContact contact: MLContact?) { coordinator.presentChat(withContact: contact) }
    @objc func presentChat(withContact contact: MLContact?, andCompletion completion: monal_id_block_t?) { coordinator.presentChat(withContact: contact, andCompletion: completion) }
    @objc func presentSplitPlaceholder() { coordinator.presentSplitPlaceholder() }
    @objc func refreshDisplay() { coordinator.refreshDisplay() }
    @objc func showContacts() { coordinator.showContacts() }
    @objc func deleteConversation() { coordinator.deleteConversation() }
    @objc func showSettings() { coordinator.showSettings() }
    @objc func showGeneralSettings() { coordinator.showGeneralSettings() }
    @objc func prependGeneralSettings() { coordinator.prependGeneralSettings() }
    @objc func prependOneClickRegistration() { coordinator.prependOneClickRegistration() }
    @objc func showNotificationSettings() { coordinator.showNotificationSettings() }
    @objc func showDetails() { coordinator.showDetails() }
    @objc func showRegister(withUsername username: String, onHost host: String, withToken token: String?, usingCompletion callback: monal_id_block_t?) {
        coordinator.showRegister(withUsername: username, onHost: host, withToken: token, usingCompletion: callback)
    }
    @objc func showAddContact(withJid jid: String, preauthToken: String?, prefillAccount account: xmpp?, andOmemoFingerprints fingerprints: NSDictionary?) {
        coordinator.showAddContact(withJid: jid, preauthToken: preauthToken, prefillAccount: account, andOmemoFingerprints: fingerprints)
    }
    @objc func showAddContact() { coordinator.showAddContact() }
    @objc func sheetDismissed() { coordinator.sheetDismissed() }
    @objc func segueToIntroScreensIfNeeded() { coordinator.segueToIntroScreensIfNeeded() }
    @objc func resetViewQueue() { coordinator.resetViewQueue() }
    @objc func dismissCompleteViewChain(withAnimation animation: Bool, andCompletion completion: (() -> Void)?) {
        coordinator.dismissCompleteViewChain(withAnimation: animation, andCompletion: completion)
    }
    @objc func updateSizeClass() { coordinator.updateSizeClass() }
}
