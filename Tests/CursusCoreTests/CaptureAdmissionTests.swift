import Testing
@testable import CursusCore

@Suite struct CaptureAdmissionTests {
    let origin = CaptureAdmission.Origin(process: "42:1", window: "A", document: "https://notes.example/a", title: "A")
    @Test func ordinaryWindowIsAllowed() {
        #expect(CaptureAdmission.admit(classification: .normal, secureInput: false, credentialApplication: false,
                                       knownProcess: true, windowAvailable: true) == .allowed)
        #expect(CaptureAdmission.revalidate(origin, current: origin, admission: .allowed, cancelled: false) == .allowed)
    }
    @Test func protectedOrUnknownSourcesNeverReceiveAdmission() {
        for classification: Classification in [.secure, .custom, .remote, .unknown] {
            #expect(CaptureAdmission.admit(classification: classification, secureInput: false, credentialApplication: false,
                                           knownProcess: true, windowAvailable: true) == .refused(.excludedApplication))
        }
        #expect(CaptureAdmission.admit(classification: .normal, secureInput: true, credentialApplication: false,
                                       knownProcess: true, windowAvailable: true) == .refused(.secureInput))
        #expect(CaptureAdmission.admit(classification: .normal, secureInput: false, credentialApplication: true,
                                       knownProcess: true, windowAvailable: true) == .refused(.excludedApplication))
        for (process, window) in [(false,true),(true,false),(false,false)] {
            #expect(CaptureAdmission.admit(classification: .normal, secureInput: false, credentialApplication: false,
                                           knownProcess: process, windowAvailable: window) == .refused(.unavailableWindow))
        }
    }
    @Test func changedProcessWindowDocumentOrTitleCannotCommit() {
        for current in [nil, CaptureAdmission.Origin(process: "42:2", window: "A", document: origin.document, title: "A"),
                        .init(process: origin.process, window: "B", document: origin.document, title: "A"),
                        .init(process: origin.process, window: "A", document: "https://notes.example/b", title: "A"),
                        .init(process: origin.process, window: "A", document: origin.document, title: "B")] {
            #expect(CaptureAdmission.revalidate(origin, current: current, admission: .allowed, cancelled: false) == .refused(.changedOrigin))
        }
        #expect(CaptureAdmission.revalidate(origin, current: origin, admission: .allowed, cancelled: true) == .refused(.cancelled))
        #expect(CaptureAdmission.revalidate(origin, current: origin, admission: .refused(.secureInput), cancelled: false) == .refused(.secureInput))
    }
    @Test func credentialApplicationsAreExcluded() {
        for name in ["Passwords", "Keychain Access", "1Password", "Bitwarden", "Dashlane", "KeePassXC",
                     "Enpass", "Proton Pass", "NordPass", "RoboForm", "Strongbox", "MacPass"] {
            #expect(CaptureAdmission.isCredentialApplication(name: name))
        }
        #expect(!CaptureAdmission.isCredentialApplication(name: "TextEdit"))
        #expect(CaptureAdmission.isCredentialApplication(name: nil, bundleID: "com.1password.1password"))
        for id in ["in.sinew.Enpass-Desktop", "me.proton.pass.electron", "com.nordpass.macos.NordPass", "com.siber.roboform", "com.markmcguill.strongbox.mac", "com.github.MacPass"] {
            #expect(CaptureAdmission.isCredentialApplication(name: nil, bundleID: id))
        }
        #expect(CaptureAdmission.isCredentialApplication(name: "Proton Pass"))
        #expect(CaptureAdmission.isCredentialApplication(name: nil, bundleID: "com.apple.Passwords"))
        #expect(CaptureAdmission.isCredentialApplication(name: nil, bundleID: "com.apple.keychainaccess"))
        #expect(!CaptureAdmission.isCredentialApplication(name: nil, bundleID: "com.apple.TextEdit"))
    }
}

@Test func unavailableOrSecureFocusCannotAuthorizeCapture() {
    for (role, subrole): (String?, String?) in [(nil,nil),("",nil),("AXUnknown",nil),("AXUnknownRole",nil),("AXTextField",nil),("AXTextField","AXUnknown"),("AXTextField","AXUnknownSubrole"),("AXTextField",""),("AXSecureTextField",nil),("AXTextField","AXSecureTextField")] {
        #expect(!CaptureAdmission.readableFocus(role: role, subrole: subrole))
    }
    #expect(CaptureAdmission.readableFocus(role: "AXWebArea", subrole: nil))
    #expect(CaptureAdmission.readableFocus(role: "AXTextField", subrole: "AXSearchField"))
}

@Test func capturePageIdentityCannotBeReplaced() {
    #expect(CaptureAdmission.samePage(expected: "https://notes.example/a", observed: "https://notes.example/a"))
    #expect(!CaptureAdmission.samePage(expected: "https://notes.example/a", observed: "https://notes.example/b"))
    #expect(!CaptureAdmission.samePage(expected: nil, observed: nil))
}
