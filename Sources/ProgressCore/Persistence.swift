import Foundation
import CoreData

// A single small text workspace is committed as one transaction. The versioned
// payload also serves as the portable backup format; no external files are tracked.
@MainActor public final class WorkspaceRepository {
    private let coordinator: NSPersistentStoreCoordinator
    private let context: NSManagedObjectContext
    private let storeURL: URL?
    public init(url: URL? = nil, inMemory: Bool = false) throws {
        storeURL = inMemory ? nil : url
        let model = NSManagedObjectModel(); model.versionIdentifiers = ["1"]
        let entity = NSEntityDescription(); entity.name = "WorkspaceDocument"; entity.managedObjectClassName = "NSManagedObject"
        let key = NSAttributeDescription(); key.name = "key"; key.attributeType = .stringAttributeType; key.isOptional = false
        let payload = NSAttributeDescription(); payload.name = "payload"; payload.attributeType = .binaryDataAttributeType; payload.isOptional = false
        let savedAt = NSAttributeDescription(); savedAt.name = "savedAt"; savedAt.attributeType = .dateAttributeType; savedAt.isOptional = false
        entity.properties = [key, payload, savedAt]; entity.uniquenessConstraints = [["key"]]; model.entities = [entity]
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType, configurationName: nil, at: inMemory ? nil : url, options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
    }
    public func load() throws -> Workspace? {
        guard let row = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkspaceDocument")).first else { return nil }
        guard let payload = row.value(forKey: "payload") as? Data else { throw WorkspaceError("资料库内容不完整，原文件已保留。") }
        return try Workspace.decoded(payload)
    }
    public func save(_ workspace: Workspace) throws {
        let bytes = try workspace.encoded()
        do {
            let row = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkspaceDocument")).first ?? NSEntityDescription.insertNewObject(forEntityName: "WorkspaceDocument", into: context)
            if let storeURL, let previous = row.value(forKey: "payload") as? Data,
               let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any], (object["version"] as? Int ?? 0) < 4 {
                let directory = storeURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try previous.write(to: directory.appendingPathComponent("before-format-upgrade-v\(object["version"] as? Int ?? 0)-\(UUID().uuidString).json"), options: .atomic)
            }
            row.setValue("workspace", forKey: "key"); row.setValue(bytes, forKey: "payload"); row.setValue(Date(), forKey: "savedAt")
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
