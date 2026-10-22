import SwiftUI
import CoreTransferable
import FileWallKit

/// Lets a vault file be dragged out of FileWall (iPad, and Mac later) into another app.
/// The file is decrypted only when the other app asks for it. Hidden-vault files never leave.
struct VaultFileTransfer: Transferable {
    let id: UUID
    let name: String
    let isHidden: Bool
    let side: VaultSideSelector

    init(item: VaultFileSnapshot, side: VaultSideSelector) {
        self.id = item.id
        self.name = item.name
        self.isHidden = item.isHidden
        self.side = side
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { transfer in
            guard !transfer.isHidden else { throw CocoaError(.fileWriteNoPermission) }
            let url = try await VaultService.shared.decryptToPreviewCache(
                id: transfer.id, name: transfer.name, side: transfer.side)
            return SentTransferredFile(url)
        }
    }
}
