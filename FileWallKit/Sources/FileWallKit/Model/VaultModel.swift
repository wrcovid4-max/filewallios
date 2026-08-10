import Foundation
import CoreData

/// The Core Data model, built in code rather than from a `.xcdatamodeld`.
///
/// Why in code: it keeps FileWallKit a plain Swift package with no resource
/// bundle to load, so the model is identical whether the tests run under
/// `swift test` on a laptop or the app runs on device — no "works in the app,
/// missing in the test bundle" resource drift. The trade-off is that a
/// lightweight-migration story would need a second `NSManagedObjectModel`
/// version object here; for v1 there is nothing to migrate from.
enum VaultModel {

    /// One shared model instance. Core Data warns if the *same* entity classes
    /// are claimed by two loaded models, so this must be a singleton.
    static let shared: NSManagedObjectModel = build()

    private static func build() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let file = NSEntityDescription()
        file.name = "VaultFile"
        file.managedObjectClassName = "VaultFile"

        let folder = NSEntityDescription()
        folder.name = "VaultFolder"
        folder.managedObjectClassName = "VaultFolder"

        file.properties = [
            attr("id", .UUIDAttributeType),
            attr("name", .stringAttributeType),
            attr("categoryRaw", .stringAttributeType),
            attr("mimeType", .stringAttributeType),
            attr("byteSize", .integer64AttributeType),
            attr("dateAdded", .dateAttributeType),
            attr("isHidden", .booleanAttributeType),
            attr("isArchived", .booleanAttributeType),
            attr("deletedAt", .dateAttributeType, optional: true)
        ]

        folder.properties = [
            attr("id", .UUIDAttributeType),
            attr("name", .stringAttributeType),
            attr("colorIndex", .integer64AttributeType),
            attr("dateCreated", .dateAttributeType),
            attr("isHidden", .booleanAttributeType)
        ]

        // Relationship: VaultFile.folder <-> VaultFolder.files, with inverses set
        // so Core Data maintains both ends. Deleting a folder nullifies its
        // files' `folder` (the files survive, they just fall back to "no folder")
        // — matching the UI where deleting a folder must never delete its
        // contents.
        let fileToFolder = NSRelationshipDescription()
        fileToFolder.name = "folder"
        fileToFolder.destinationEntity = folder
        fileToFolder.minCount = 0
        fileToFolder.maxCount = 1            // to-one
        fileToFolder.deleteRule = .nullifyDeleteRule
        fileToFolder.isOptional = true

        let folderToFiles = NSRelationshipDescription()
        folderToFiles.name = "files"
        folderToFiles.destinationEntity = file
        folderToFiles.minCount = 0
        folderToFiles.maxCount = 0           // 0 == to-many
        folderToFiles.deleteRule = .nullifyDeleteRule
        folderToFiles.isOptional = true

        fileToFolder.inverseRelationship = folderToFiles
        folderToFiles.inverseRelationship = fileToFolder

        file.properties.append(fileToFolder)
        folder.properties.append(folderToFiles)

        model.entities = [file, folder]
        return model
    }

    private static func attr(_ name: String,
                             _ type: NSAttributeType,
                             optional: Bool = false) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        return a
    }
}
