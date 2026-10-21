import Foundation
import MSIScreenCore

// U3 owns hidden runtime dispatch only. Public lifecycle/control commands are U4.
func dispatchInternalSupportMode(_ arguments: [String]) async -> Int32? {
    await AdapterProcessHost.runInternalMode(arguments)
}
