import MobileCoreServices
import UniformTypeIdentifiers

struct NewChatView: View {
    var delegate: SheetDismisserProtocol
    static private let jidFaultyPattern = "^([^@]+@)?.+(\\..{2,})?$"

    @State private var enabledAccounts: [xmpp]
    @State private var selectedAccount: Int
    @State private var scannedFingerprints: [NSNumber:Data]? = nil
    @State private var importScannedFingerprints: Bool = false
    @State private var toAdd: String = ""

    @State private var showInvitationError = false
    @State private var showAlert = false
    @State private var alertPrompt = AlertPrompt(dismissLabel: Text("Close"))
    @State private var invitationResult: [String:AnyObject]? = nil

    @StateObject private var overlay = LoadingOverlayState()

    @State private var showQRCodeScanner = false
    @State private var success = false
    @State private var newContact: MLContact?

    @State private var isEditingJid = false

    // Contact list state
    @ObservedObject private var contacts: Contacts
    @State private var searchText: String = ""

    private let dismissWithContact: (MLContact) -> ()
    private let preauthToken: String?

    init(contacts: Contacts, delegate: SheetDismisserProtocol, dismissWithContact: @escaping (MLContact) -> (), prefillJid: String = "", preauthToken: String? = nil, prefillAccount: xmpp? = nil, omemoFingerprints: [NSNumber:Data]? = nil) {
        self.contacts = contacts
        self.delegate = delegate
        self.dismissWithContact = dismissWithContact
        self.toAdd = prefillJid
        self.preauthToken = preauthToken
        if omemoFingerprints?.count ?? 0 > 0 {
            self.scannedFingerprints = omemoFingerprints
        }

        let enabledAccounts = MLXMPPManager.sharedInstance().connectedXMPP as! [xmpp]
        self.enabledAccounts = enabledAccounts
        self.selectedAccount = enabledAccounts.first != nil ? 0 : -1
        if let prefillAccount = prefillAccount {
            for index in enabledAccounts.indices {
                if enabledAccounts[index].accountID.isEqual(to: prefillAccount.accountID) {
                    self.selectedAccount = index
                }
            }
        }
    }

    // MARK: - JID Validation

    private var toAddEmptyAlert: Bool {
        alertPrompt.title = Text("No Empty Values!")
        alertPrompt.message = Text("Please make sure you have entered a valid jid.")
        return toAddEmpty
    }

    private var toAddInvalidAlert: Bool {
        alertPrompt.title = Text("Invalid Credentials!")
        alertPrompt.message = Text("The jid you want to add should be in in the format user@domain.tld.")
        return toAddInvalid
    }

    private func errorAlert(title: Text, message: Text = Text("")) {
        alertPrompt.title = title
        alertPrompt.message = message
        showAlert = true
    }

    private func successAlert(title: Text, message: Text) {
        alertPrompt.title = title
        alertPrompt.message = message
        self.success = true
        showAlert = true
    }

    private var toAddEmpty: Bool {
        return toAdd.isEmpty
    }

    private var toAddInvalid: Bool {
        return toAdd.range(of: NewChatView.jidFaultyPattern, options: .regularExpression) == nil
    }

    // MARK: - Contact List

    private static func shouldDisplayContact(_ contact: MLContact) -> Bool {
        return contact.isSubscribedTo || contact.hasOutgoingContactRequest || contact.isSubscribedFrom
    }

    private static func isNotSelfChatContact(contact: MLContact) -> Bool {
        return !contact.isSelf && NewChatView.shouldDisplayContact(contact)
    }

    private var contactList: [MLContact] {
        let withoutSelfChats = contacts.contacts.filter(NewChatView.isNotSelfChatContact)
        if withoutSelfChats.count == 0 {
            return []
        }
        return contacts.contacts
            .filter(NewChatView.shouldDisplayContact)
            .sorted { ($0.contactDisplayName.lowercased(), $0.contactJid.lowercased()) < ($1.contactDisplayName.lowercased(), $1.contactJid.lowercased()) }
    }

    private var searchResults: [MLContact] {
        if searchText.isEmpty { return contactList }
        return contactList.filter { contact in
            let jid = contact.contactJid.lowercased()
            let name = contact.contactDisplayName.lowercased()
            let search = searchText.lowercased()
            return jid.contains(search) || name.contains(search)
        }
    }

    // MARK: - Add Contact Logic

    func trustFingerprints(_ fingerprints: [NSNumber:Data]?, for jid: String, on account: xmpp) {
        if let fingerprints = fingerprints {
            for (deviceId, fingerprint) in fingerprints {
                let address = SignalAddress.init(name: jid, deviceId: deviceId.int32Value)
                let knownDevices = Array(account.omemo.knownDevices(forAddressName: jid))
                if !knownDevices.contains(deviceId) {
                    account.omemo.addIdentityManually(address, identityKey: fingerprint)
                    assert(account.omemo.getIdentityFor(address) == fingerprint, "The stored and created fingerprint should match")
                }
                let knownFingerprintHex = HelperTools.signalHexKey(with: account.omemo.getIdentityFor(address))
                let addedFingerprintHex = HelperTools.signalHexKey(with: fingerprint)
                if knownFingerprintHex.uppercased() == addedFingerprintHex.uppercased() {
                    account.omemo.updateTrust(true, for: address)
                }
            }
        }
    }

    func addJid(jid: String) {
        let account = self.enabledAccounts[selectedAccount]
        let contact = MLContact.createContact(fromJid: jid, andAccountID: account.accountID)
        if contact.isInRoster {
            self.newContact = contact
            trustFingerprints(self.importScannedFingerprints ? self.scannedFingerprints : [:], for: jid, on: account)
            if !self.importScannedFingerprints || self.scannedFingerprints?.count ?? 0 == 0 {
                if self.enabledAccounts.count > 1 {
                    self.success = true
                    successAlert(title: Text("Already present"), message: Text("This contact is already in the contact list of the selected account"))
                } else {
                    self.success = true
                    successAlert(title: Text("Already present"), message: Text("This contact is already in your contact list"))
                }
            }
            return
        }
        showPromisingLoadingOverlay(overlay, headline: "Adding...", description: "") {
            account.checkJidType(jid)
        }.done { type in
            let type = type as! String
            if type == "account" {
                let contact = MLContact.createContact(fromJid: jid, andAccountID: account.accountID)
                self.newContact = contact
                MLXMPPManager.sharedInstance().add(contact, withPreauthToken: preauthToken)
                trustFingerprints(self.importScannedFingerprints ? self.scannedFingerprints : [:], for: jid, on: account)
                successAlert(title: Text("Permission Requested"), message: Text("The new contact will be added to your contacts list when the person you've added has approved your request."))
            } else if type == "muc" {
                showPromisingLoadingOverlay(overlay, headlineView: Text("Adding Group/Channel..."), descriptionView: Text("")) {
                    promisifyMucAction(account: account, mucJid: jid) {
                        account.joinMuc(jid)
                    }
                }.done { _ in
                    self.newContact = MLContact.createContact(fromJid: jid, andAccountID: account.accountID)
                    successAlert(title: Text("Success!"), message: Text("Successfully joined group/channel \(jid)!"))
                }.catch { error in
                    errorAlert(title: Text("Error entering group/channel!"), message: Text(error.localizedDescription))
                }
            }
        }.catch { error in
            errorAlert(title: Text("Error"), message: Text(error.localizedDescription))
        }
    }

    // MARK: - Body

    var body: some View {
        let account = self.enabledAccounts[selectedAccount]
        let splitJid = HelperTools.splitJid(account.connectionProperties.identity.jid)
        List {
            if enabledAccounts.isEmpty {
                Section {
                    Text("Please make sure at least one account has connected before trying to add a contact or channel.")
                        .foregroundColor(.secondary)
                }
            } else {
                if DataLayer.sharedInstance().allContactRequests().count > 0 {
                    ContactRequestsMenu()
                }

                Section(header: Text("Contact and Group/Channel Jids are usually in the format: name@domain.tld")) {
                    if enabledAccounts.count > 1 {
                        Picker("Use account", selection: $selectedAccount) {
                            ForEach(Array(self.enabledAccounts.enumerated()), id: \.element) { idx, account in
                                Text(account.connectionProperties.identity.jid).tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    TextField(NSLocalizedString("Contact-, Group- or Channel-Jid", comment: "placeholder when adding jid"), text: $toAdd, onEditingChanged: { isEditingJid = $0 })
                        .textInputAutocapitalization(.never)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .addClearButton(isEditing: isEditingJid, text: $toAdd)
                        .disabled(scannedFingerprints != nil)
                        .foregroundColor(scannedFingerprints != nil ? .secondary : .primary)
                        .onChange(of: toAdd) { _ in toAdd = toAdd.replacingOccurrences(of: " ", with: "") }

                    if scannedFingerprints != nil && scannedFingerprints!.count > 0 {
                        Section(header: Text("A contact was scanned through the QR code scanner")) {
                            Toggle(isOn: $importScannedFingerprints) {
                                Text("Import and trust OMEMO fingerprints from QR code")
                            }
                        }
                    }

                    if scannedFingerprints != nil {
                        Button(action: {
                            toAdd = ""
                            importScannedFingerprints = true
                            scannedFingerprints = nil
                        }, label: {
                            Text("Clear scanned contact")
                                .foregroundColor(.red)
                        })
                    }

                    HStack {
                        Spacer()
                        Button(action: {
                            showAlert = toAddEmptyAlert || toAddInvalidAlert
                            if !showAlert {
                                let jidComponents = HelperTools.splitJid(toAdd)
                                if jidComponents["host"] == nil || jidComponents["host"]!.isEmpty {
                                    errorAlert(title: Text("Error"), message: Text("Something went wrong while parsing your input..."))
                                    showAlert = true
                                    return
                                }
                                addJid(jid: jidComponents["user"]!)
                            }
                        }) {
                            scannedFingerprints == nil ? Text("Add") : Text("Add scanned contact")
                        }
                        .disabled(toAddEmpty || toAddInvalid)
                        .buttonStyle(MonalProminentButtonStyle())
                    }
                }

                if DataLayer.sharedInstance().allContactRequests().count == 0 {
                    Section {
                        ContactRequestsMenu()
                    }
                }
            }

            // Contact list section
            if !contactList.isEmpty {
                Section(header: Text("Contacts")) {
                    ForEach(searchResults, id: \.self) { contact in
                        Button(action: { dismissWithContact(contact) }) {
                            ContactEntry(contact: contact)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: contactList)
        .alert(isPresented: $showAlert) {
            Alert(title: alertPrompt.title, message: alertPrompt.message, dismissButton: .default(Text("Close"), action: {
                showAlert = false
                if self.success == true {
                    if self.newContact != nil {
                        self.dismissWithContact(newContact!)
                    } else {
                        self.delegate.dismiss()
                    }
                }
            }))
        }
        .richAlert(isPresented: $invitationResult, title: Text("Invitation for \(splitJid["host"]!) created")) { data in
            VStack {
                Image(uiImage: createQrCode(value: data["landing"] as! String))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(1, contentMode: .fit)

                if let expires = data["expires"] as? Date {
                    Text("This invitation will expire on \(expires.formatted(date: .numeric, time: .shortened))")
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } buttons: { data in
            Button(action: {
                UIPasteboard.general.setValue(data["landing"] as! String, forPasteboardType: UTType.utf8PlainText.identifier as String)
                invitationResult = nil
            }) {
                ShareLink("Share invitation link", item: URL(string: data["landing"] as! String)!)
            }
            Button(action: {
                invitationResult = nil
            }) {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showQRCodeScanner) {
            NavigationStack {
                MLQRCodeScanner(handleClose: {
                    self.showQRCodeScanner = false
                })
                .navigationTitle(Text("QR-Code Scanner"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(content: {
                    ToolbarItem(placement: .navigationBarLeading, content: {
                        Button(action: {
                            self.showQRCodeScanner = false
                        }, label: {
                            Text("Close")
                        })
                    })
                })
            }
        }
        .navigationBarTitle(Text("New Chat"), displayMode: .inline)
        .toolbar(content: {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if account.connectionProperties.discoveredAdhocCommands["urn:xmpp:invite#invite"] != nil {
                    Button(action: {
                        DDLogVerbose("Trying to create invitation for: \(String(describing:splitJid["host"]!))")
                        showLoadingOverlay(overlay, headline: "Creating invitation...")
                        account.createInvitation(completion: {
                            let result = $0 as! [String:AnyObject]
                            DispatchQueue.main.async {
                                hideLoadingOverlay(overlay)
                                DDLogVerbose("Got invitation result: \(String(describing:result))")
                                if result["success"] as! Bool == true {
                                    invitationResult = result
                                } else {
                                    errorAlert(title: Text("Failed to create invitation for \(splitJid["host"]!)"), message: Text(result["error"] as! String))
                                }
                            }
                        })
                    }, label: {
                        Image(systemName: "square.and.arrow.up")
                    })
                }
                Button(action: {
                    self.showQRCodeScanner = true
                }, label: {
                    Image(systemName: "camera.fill")
                })
            }
        })
        .addLoadingOverlay(overlay)
    }
}
