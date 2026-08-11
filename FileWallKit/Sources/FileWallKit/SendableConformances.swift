import Foundation

// NSPredicate and NSSortDescriptor are immutable once constructed — there is no
// mutable subclass we use, we build them and never touch them again, and we hand
// them straight to the `VaultStore` actor. The iOS 16 SDK does not yet mark them
// `Sendable`, so passing them across the actor boundary warns. Declare the
// conformance here (`@unchecked` = we are asserting the thread-safety Foundation
// hasn't formally promised on this SDK) so the query API stays warning-clean.
//
// If a future SDK marks these Sendable itself, remove this file to avoid a
// redundant-conformance warning.
extension NSPredicate: @unchecked Sendable {}
extension NSSortDescriptor: @unchecked Sendable {}
