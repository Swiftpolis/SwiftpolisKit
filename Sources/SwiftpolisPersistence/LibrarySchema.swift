import Foundation
import SwiftData
import SwiftpolisDomain

/// The first released shape of the library. It stays exactly as it was, for migration.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CategoryRecord.self, DownloadRecord.self] }

    @Model
    final class CategoryRecord {
        @Attribute(.unique) var name: String
        var sidePanelPosition: Int
        var startTimeEnabled = false
        var startTimeMinutes = 0
        var endTimeEnabled = false
        var endTimeMinutes = 0
        var isReversed = false
        var shutsDownAfterDownload = false

        @Relationship(deleteRule: .cascade, inverse: \DownloadRecord.category)
        var downloads: [DownloadRecord] = []

        init(name: String, sidePanelPosition: Int) {
            self.name = name
            self.sidePanelPosition = sidePanelPosition
        }
    }

    @Model
    final class DownloadRecord {
        @Attribute(.unique) var gid: String
        var category: CategoryRecord?

        // Relationships have no order of their own, and a Download has one place in its
        // Category's list and another in All Downloads. Lists show the highest position first.
        var categoryPosition: Int
        var allDownloadsPosition: Int

        var statusRawValue: String
        var fileName: String?
        var filePath: String?
        var totalBytes: Int64?
        var downloadedBytes: Int64 = 0
        var firstTryDate: Date
        var lastTryDate: Date

        var link: String
        var customFileName: String?
        var folder: String
        var connections: Int
        var speedDial: Int
        var startTimeMinutes: Int?
        var endTimeMinutes: Int?
        var proxyKindRawValue: String?
        var proxyHost: String?
        var proxyPort: Int?
        var proxyUser: String?
        var httpUser: String?
        var referer: String?
        var userAgent: String?
        var headers: String?
        var cookieFilePath: String?
        var shutsDownAfterDownload: Bool

        init(
            gid: String,
            categoryPosition: Int,
            allDownloadsPosition: Int,
            statusRawValue: String,
            date: Date,
            link: String,
            customFileName: String?,
            folder: String,
            connections: Int,
            speedDial: Int,
            startTimeMinutes: Int?,
            endTimeMinutes: Int?,
            proxyKindRawValue: String?,
            proxyHost: String?,
            proxyPort: Int?,
            proxyUser: String?,
            httpUser: String?,
            referer: String?,
            userAgent: String?,
            headers: String?,
            cookieFilePath: String?,
            shutsDownAfterDownload: Bool
        ) {
            self.gid = gid
            self.categoryPosition = categoryPosition
            self.allDownloadsPosition = allDownloadsPosition
            self.statusRawValue = statusRawValue
            self.fileName = customFileName
            self.firstTryDate = date
            self.lastTryDate = date
            self.link = link
            self.customFileName = customFileName
            self.folder = folder
            self.connections = connections
            self.speedDial = speedDial
            self.startTimeMinutes = startTimeMinutes
            self.endTimeMinutes = endTimeMinutes
            self.proxyKindRawValue = proxyKindRawValue
            self.proxyHost = proxyHost
            self.proxyPort = proxyPort
            self.proxyUser = proxyUser
            self.httpUser = httpUser
            self.referer = referer
            self.userAgent = userAgent
            self.headers = headers
            self.cookieFilePath = cookieFilePath
            self.shutsDownAfterDownload = shutsDownAfterDownload
        }
    }
}

enum LibrarySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [CategoryRecord.self, DownloadRecord.self, VideoPairRecord.self] }

    @Model
    final class CategoryRecord {
        @Attribute(.unique) var name: String
        var sidePanelPosition: Int
        var startTimeEnabled = false
        var startTimeMinutes = 0
        var endTimeEnabled = false
        var endTimeMinutes = 0
        var isReversed = false
        var shutsDownAfterDownload = false

        @Relationship(deleteRule: .cascade, inverse: \DownloadRecord.category)
        var downloads: [DownloadRecord] = []

        init(name: String, sidePanelPosition: Int) {
            self.name = name
            self.sidePanelPosition = sidePanelPosition
        }
    }

    @Model
    final class DownloadRecord {
        @Attribute(.unique) var gid: String
        var category: CategoryRecord?

        // Relationships have no order of their own, and a Download has one place in its
        // Category's list and another in All Downloads. Lists show the highest position first.
        var categoryPosition: Int
        var allDownloadsPosition: Int

        var statusRawValue: String
        var fileName: String?
        var filePath: String?
        var totalBytes: Int64?
        var downloadedBytes: Int64 = 0
        var firstTryDate: Date
        var lastTryDate: Date

        var link: String
        var customFileName: String?
        var folder: String
        var connections: Int
        var speedDial: Int
        var startTimeMinutes: Int?
        var endTimeMinutes: Int?
        var proxyKindRawValue: String?
        var proxyHost: String?
        var proxyPort: Int?
        var proxyUser: String?
        var httpUser: String?
        var referer: String?
        var userAgent: String?
        var headers: String?
        var cookieFilePath: String?
        var shutsDownAfterDownload: Bool
        var engineKindRawValue = DownloadEngineKind.http.rawValue

        init(
            gid: String,
            categoryPosition: Int,
            allDownloadsPosition: Int,
            statusRawValue: String,
            date: Date,
            link: String,
            customFileName: String?,
            folder: String,
            connections: Int,
            speedDial: Int,
            startTimeMinutes: Int?,
            endTimeMinutes: Int?,
            proxyKindRawValue: String?,
            proxyHost: String?,
            proxyPort: Int?,
            proxyUser: String?,
            httpUser: String?,
            referer: String?,
            userAgent: String?,
            headers: String?,
            cookieFilePath: String?,
            shutsDownAfterDownload: Bool,
            engineKindRawValue: String
        ) {
            self.gid = gid
            self.categoryPosition = categoryPosition
            self.allDownloadsPosition = allDownloadsPosition
            self.statusRawValue = statusRawValue
            self.fileName = customFileName
            self.firstTryDate = date
            self.lastTryDate = date
            self.link = link
            self.customFileName = customFileName
            self.folder = folder
            self.connections = connections
            self.speedDial = speedDial
            self.startTimeMinutes = startTimeMinutes
            self.endTimeMinutes = endTimeMinutes
            self.proxyKindRawValue = proxyKindRawValue
            self.proxyHost = proxyHost
            self.proxyPort = proxyPort
            self.proxyUser = proxyUser
            self.httpUser = httpUser
            self.referer = referer
            self.userAgent = userAgent
            self.headers = headers
            self.cookieFilePath = cookieFilePath
            self.shutsDownAfterDownload = shutsDownAfterDownload
            self.engineKindRawValue = engineKindRawValue
        }
    }

    /// A video stream and an audio stream that end up as one file. Each stream is a DownloadRecord.
    @Model
    final class VideoPairRecord {
        @Attribute(.unique) var videoGID: String
        @Attribute(.unique) var audioGID: String
        var muxingStatusRawValue = MuxingStatus.notStarted.rawValue

        init(videoGID: String, audioGID: String) {
            self.videoGID = videoGID
            self.audioGID = audioGID
        }
    }
}


typealias CategoryRecord = LibrarySchemaV2.CategoryRecord
typealias DownloadRecord = LibrarySchemaV2.DownloadRecord
typealias VideoPairRecord = LibrarySchemaV2.VideoPairRecord

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self, LibrarySchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LibrarySchemaV1.self, toVersion: LibrarySchemaV2.self)]
    }
}

public enum LibraryStore {
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(schema: schema, url: url))
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        try makeContainer(
            ModelConfiguration(UUID().uuidString, schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private static let schema = Schema(versionedSchema: LibrarySchemaV2.self)

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: LibraryMigrationPlan.self,
            configurations: configuration
        )
    }
}
