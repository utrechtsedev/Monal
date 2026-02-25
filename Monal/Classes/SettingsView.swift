//
//  SettingsView.swift
//  Monal
//
//  Created by A Nou on 25/02/2026.
//  Copyright © 2026 monal-im.org. All rights reserved.
//


//
//  SettingsView.swift
//  Monal
//
//  Created by Abdelmoughit Ichou
//  Copyright © 2025 Risker. All rights reserved.
//

// MARK: - Settings View

import SwiftUI;
import ViewExtractor;

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        List {
            // MARK: Accounts Section
            Section {
                ForEach(viewModel.accounts) { account in
                    Button {
                        viewModel.editAccount(account)
                    } label: {
                        AccountRowView(account: account)
                    }
                }
                
                Button {
                    viewModel.addQuickAccount()
                } label: {
                    HStack {
                        Text("Add Account")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundColor(.primary)
                
                Button {
                    viewModel.addAdvancedAccount()
                } label: {
                    HStack {
                        Text("Add Account (advanced)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundColor(.primary)
            }

            // MARK: App Section
            Section(header: Text("App")) {
                            NavigationLink(destination: LazyClosureView(UserInterfaceSettings())) {
                                HStack {
                                    Image(systemName: "hand.tap.fill")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("User Interface")
                                }
                            }
                            
                            NavigationLink(destination: LazyClosureView(SecuritySettings())) {
                                HStack {
                                    Image(systemName: "shield.checkerboard")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("Security")
                                }
                            }
                            
                            NavigationLink(destination: LazyClosureView(PrivacySettings())) {
                                HStack {
                                    Image(systemName: "eye")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("Privacy")
                                }
                            }
                            
                            NavigationLink(destination: LazyClosureView(NotificationSettings())) {
                                HStack {
                                    Image(systemName: "text.bubble")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("Notifications")
                                }
                            }
                            
                            NavigationLink(destination: LazyClosureView(AttachmentSettings())) {
                                HStack {
                                    Image(systemName: "paperclip")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("Attachments")
                                }
                            }
                            
                            Button {
                                viewModel.showSounds()
                            } label: {
                                HStack {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                    Text("Sounds")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundColor(.primary)
                        }

            // MARK: About Section
            Section(header: Text("About")) {
                Button {
                    viewModel.showPrivacy()
                } label: {
                    HStack {
                        Text("Privacy")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundColor(.primary)
                
                #if DEBUG
                Button {
                    viewModel.showDebug()
                } label: {
                    HStack {
                        Text("Debug")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundColor(.primary)
                #else
                if viewModel.showDebugRow {
                    Button {
                        viewModel.showDebug()
                    } label: {
                        HStack {
                            Text("Debug")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.primary)
                }
                #endif
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .onAppear {
            viewModel.refresh()
        }
    }
}

// MARK: - Account Row

struct AccountRowView: View {
    let account: AccountInfo

    var body: some View {
        HStack(spacing: 12) {
            // Account avatar
            if let contact = account.contact {
                Image(uiImage: contact.avatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.gray)
                    )
            }
            
            // Account info
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Text(account.jid)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Connection status indicator
            Circle()
                .fill(account.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - ViewModel

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var accounts: [AccountInfo] = []
    @Published var showDebugRow: Bool = false

    init() {
        for name in [kMonalFinishedCatchup, kMonalConnectivityChange] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAccountUpdate),
                name: NSNotification.Name(name),
                object: nil
            )
        }
    }

    @objc private func handleAccountUpdate(_ notification: Notification) {
        DispatchQueue.main.async {
            self.refresh()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func refresh() {
        // Get debug row visibility setting
        showDebugRow = HelperTools.defaultsDB().bool(forKey: "showLogInSettings")
        
        // Get account list from DataLayer
        guard let accountList = DataLayer.sharedInstance().accountList() as? [[String: AnyObject]] else {
            accounts = []
            return
        }
        
        // Map accounts to AccountInfo
        accounts = accountList.enumerated().compactMap { index, accountDict -> AccountInfo? in
            guard let accountID = accountDict["account_id"] as? NSNumber,
                  let username = accountDict["username"] as? String,
                  let domain = accountDict["domain"] as? String else {
                return nil
            }
            
            let jid = "\(username)@\(domain)"
            
            // Create contact for this account
            let contact = MLContact.createContact(fromJid: jid, andAccountID: accountID)
            
            // Check connection status
            let isConnected = MLXMPPManager.sharedInstance().isAccount(forIdConnected: accountID)
            
            return AccountInfo(
                accountNo: accountID,
                displayName: username,
                jid: jid,
                isConnected: isConnected,
                contact: contact,
                originalIndex: index
            )
        }
    }
    
    // MARK: - Navigation Actions
    
    func editAccount(_ account: AccountInfo) {
        let storyboard = UIStoryboard(name: "Settings", bundle: nil)
        let editor = storyboard.instantiateViewController(withIdentifier: "XMPPEditAccount")
        
        // Use setValue to bypass type checking
        editor.setValue(account.accountNo, forKey: "accountID")
        editor.setValue(IndexPath(row: account.originalIndex, section: 0), forKey: "originIndex")
        
        // Wrap in navigation controller
        let nav = UINavigationController(rootViewController: editor)
        presentViewController(nav)
    }
    
    func addQuickAccount() {
        let loginView = SwiftuiInterface().makeView(name: "LogIn")
        presentViewController(loginView)
    }
    
    func addAdvancedAccount() {
        let view = SwiftuiInterface().makeView(name: "AdvancedLogIn")
        presentViewController(view)
    }
    
    func showGeneralSettings() {
        let view = SwiftuiInterface().makeView(name: "GeneralSettings")
        presentViewController(view)
    }
    
    func showSounds() {
        let storyboard = UIStoryboard(name: "Settings", bundle: nil)
        let soundsVC = storyboard.instantiateViewController(withIdentifier: "SoundsViewController")
        presentViewController(soundsVC)
    }
    
    func showPrivacy() {
        if let url = URL(string: "https://monal-im.org/privacy") {
            #if !APP_EXTENSION
            UIApplication.shared.open(url)
            #endif
        }
    }
    
    func showDebug() {
        let view = SwiftuiInterface().makeView(name: "DebugView")
        presentViewController(view)
    }
    
    private func presentViewController(_ viewController: UIViewController) {
        #if !APP_EXTENSION
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(viewController, animated: true)
        }
        #endif
    }
}

// MARK: - Account Model

struct AccountInfo: Identifiable {
    let id = UUID()
    let accountNo: NSNumber
    let displayName: String
    let jid: String
    let isConnected: Bool
    let contact: MLContact?
    let originalIndex: Int
}

// MARK: - Preview Provider

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView()
        }
    }
}
#endif
