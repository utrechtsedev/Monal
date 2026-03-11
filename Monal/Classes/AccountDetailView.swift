//
//  AccountDetailView.swift
//  Monal
//
//  Created by A Nou on 11/03/2026.
//  Copyright © 2026 monal-im.org. All rights reserved.
//

import SwiftUI

struct AccountDetailView: View {
    let accountNo: NSNumber

    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) var colorScheme

    @State private var displayName: String = ""
    @State private var statusMessage: String = ""
    @State private var jid: String = ""
    @State private var contact: MLContact?
    @State private var isConnected: Bool = false

    @State private var showingImagePicker = false
    @State private var inputImage: UIImage?
    @State private var avatarImage: UIImage?

    @State private var showingClearHistoryConfirmation = false
    @State private var showingRemoveAccountConfirmation = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var showingDeleteAccountError = false
    @State private var deleteAccountErrorMessage = ""

    @StateObject private var overlay = LoadingOverlayState()

    @State private var xmppAccount: xmpp?

    var body: some View {
        Form {
            // MARK: Profile Section
            Section {
                // Avatar
                HStack {
                    Spacer()
                    if let image = avatarImage ?? contact?.avatar {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                            .id(colorScheme)
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                            )
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .onTapGesture {
                    showingImagePicker = true
                }

                HStack {
                    Text("Display Name")
                    Spacer()
                    TextField("Display Name", text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            xmppAccount?.publishRosterName(displayName)
                        }
                }

                HStack {
                    Text("Status Message")
                    Spacer()
                    TextField("Your status", text: $statusMessage)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            xmppAccount?.publishStatusMessage(statusMessage)
                        }
                }
            }

            // MARK: Settings Section
            Section {
                if let account = xmppAccount {
                    NavigationLink(destination: LazyClosureView(BlockedUsers(xmppAccount: account))) {
                        Text("Blocked Users")
                    }
                } else {
                    Text("Blocked Users")
                        .foregroundColor(.secondary)
                }
            }

            // MARK: Danger Zone
            Section {
                Button(role: .destructive) {
                    showingClearHistoryConfirmation = true
                } label: {
                    Text("Clear Chat History")
                }
                .confirmationDialog("Clear Chat History", isPresented: $showingClearHistoryConfirmation, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) {
                        clearHistory()
                    }
                } message: {
                    Text("This will clear the whole chat history of this account from this device.")
                }

                Button(role: .destructive) {
                    showingRemoveAccountConfirmation = true
                } label: {
                    Text("Remove Account from this Device")
                }
                .confirmationDialog("Remove Account", isPresented: $showingRemoveAccountConfirmation, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) {
                        removeAccount()
                    }
                } message: {
                    Text("This will remove this account and the associated data from this device.")
                }

                Button(role: .destructive) {
                    deleteAccountOnServer()
                } label: {
                    Text("Delete Account on Server")
                }
                .confirmationDialog("Delete Account on Server", isPresented: $showingDeleteAccountConfirmation, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        performDeleteAccountOnServer()
                    }
                } message: {
                    Text("This will delete this account and the associated data from the server and this device. Data might still be retained on other devices, though.")
                }
            }
        }
        .navigationTitle(jid)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: $showingDeleteAccountError) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(deleteAccountErrorMessage)
        }
        .onAppear {
            loadAccountDetails()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name(kMonalContactRefresh)).receive(on: RunLoop.main)) { _ in
            loadAccountDetails()
        }
        .addLoadingOverlay(overlay)
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(image: $inputImage)
        }
        .sheet(isPresented: $inputImage.optionalMappedToBool()) {
            ImageCropView(originalImage: inputImage!, configureBlock: { cropViewController in
                cropViewController.aspectRatioPreset = .presetSquare
                cropViewController.aspectRatioLockEnabled = true
                cropViewController.aspectRatioPickerButtonHidden = true
                cropViewController.resetAspectRatioEnabled = false
            }, onCanceled: {
                inputImage = nil
            }) { (image, cropRect, angle) in
                guard image.jpegData(compressionQuality: 1.0) != nil else { return }
                avatarImage = image
                if let contact = contact {
                    // Write new avatar to disk
                    let imageData = HelperTools.resizeAvatarImage(image, withCircularMask: false, toMaxBase64Size: 60000)
                    MLImageManager.sharedInstance().setIconFor(contact, with: imageData)
                    // Purge entire NSCache (workaround for cache key mismatch) and notify all views
                    MLImageManager.sharedInstance().purgeCache()
                    MLNotificationQueue.current().post(name: NSNotification.Name(kMonalContactRefresh), object: xmppAccount, userInfo: ["contact": contact])
                }
                xmppAccount?.publishAvatar(image)
                inputImage = nil
            }
        }
    }

    // MARK: - Data Loading

    private func loadAccountDetails() {
        guard let settings = DataLayer.sharedInstance().details(forAccount: accountNo) else { return }

        let username = settings["username"] as? String ?? ""
        let domain = settings["domain"] as? String ?? ""
        jid = "\(username)@\(domain)"

        contact = MLContact.createContact(fromJid: jid, andAccountID: accountNo)
        xmppAccount = MLXMPPManager.sharedInstance().getEnabledAccount(forID: accountNo)
        isConnected = MLXMPPManager.sharedInstance().isAccount(forIdConnected: accountNo)

        if let c = contact {
            displayName = c.fullName
        } else {
            displayName = settings[kRosterName] as? String ?? username
        }
        statusMessage = xmppAccount?.statusMessage ?? settings["statusMessage"] as? String ?? ""
    }

    // MARK: - Actions

    private func clearHistory() {
        DataLayer.sharedInstance().clearMessages(accountNo)

        let currentContact = MLNotificationManager.sharedInstance().currentContact
        if let currentContact = currentContact, currentContact.accountID == accountNo {
            MLNotificationManager.sharedInstance().currentContact = nil
        }

        MLNotificationQueue.current().post(name: NSNotification.Name(kMonalRefresh), object: nil, userInfo: nil)
    }

    private func removeAccount() {
        MLXMPPManager.sharedInstance().removeAccount(forAccountID: accountNo)
        presentationMode.wrappedValue.dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HelperTools.defaultsDB().removeObject(forKey: "Quicksy_phoneNumber")
            HelperTools.defaultsDB().removeObject(forKey: "Quicksy_country")
            let appDelegate = UIApplication.shared.delegate as! MonalAppDelegate
            appDelegate.activeChats?.segueToIntroScreensIfNeeded()
        }
    }

    private func deleteAccountOnServer() {
        guard let account = xmppAccount, account.accountState.rawValue >= xmppState.stateInitStarted.rawValue else {
            deleteAccountErrorMessage = NSLocalizedString("Your account must be enabled and connected, to be removed from the server!", comment: "")
            showingDeleteAccountError = true
            return
        }
        showingDeleteAccountConfirmation = true
    }

    private func performDeleteAccountOnServer() {
        guard let account = xmppAccount else { return }

        showLoadingOverlay(overlay, headlineView: Text("Deleting account..."), descriptionView: Text(""))

        account.removeFromServer { error in
            DispatchQueue.main.async {
                hideLoadingOverlay(overlay)
                if let error = error {
                    deleteAccountErrorMessage = error
                    showingDeleteAccountError = true
                } else {
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        HelperTools.defaultsDB().removeObject(forKey: "Quicksy_phoneNumber")
                        HelperTools.defaultsDB().removeObject(forKey: "Quicksy_country")
                        let appDelegate = UIApplication.shared.delegate as! MonalAppDelegate
                        appDelegate.activeChats?.segueToIntroScreensIfNeeded()
                    }
                }
            }
        }
    }
}
