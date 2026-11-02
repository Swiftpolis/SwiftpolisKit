import Foundation
import SwiftData
import SwiftpolisDomain

/// All reads and writes of Categories and Downloads. It returns plain values, never models.
@ModelActor
public actor LibraryRepository {
    /// Creates any missing built-in Category, then applies Persepolis's launch reset: nothing
    /// resumes by itself, and schedules don't survive quitting.
    public func prepareForLaunch() throws {
        let existing = Set(try fetchCategories().map(\.name))
        var position = try fetchCategories().map(\.sidePanelPosition).max() ?? -1
        for name in CategoryKind.builtInNames where !existing.contains(name) {
            position += 1
            modelContext.insert(CategoryRecord(name: name, sidePanelPosition: position))
        }

        for category in try fetchCategories() {
            category.startTimeEnabled = false
            category.endTimeEnabled = false
            category.isReversed = false
            category.shutsDownAfterDownload = false
        }
        for download in try modelContext.fetch(FetchDescriptor<DownloadRecord>()) {
            let status = DownloadStatus(rawValue: download.statusRawValue) ?? .stopped
            download.statusRawValue = status.afterLaunch.rawValue
            download.startTimeMinutes = nil
            download.endTimeMinutes = nil
            download.shutsDownAfterDownload = false
        }
        try modelContext.save()
    }

    // MARK: Categories

    public func categories() throws -> [CategorySummary] {
        try fetchCategories().map(summary(of:))
    }

    public func createQueue(named name: String) throws {
        let categories = try fetchCategories()
        try CategoryKind.validateNewQueueName(name, existing: categories.map(\.name))
        let position = (categories.map(\.sidePanelPosition).max() ?? -1) + 1
        modelContext.insert(CategoryRecord(name: name, sidePanelPosition: position))
        try modelContext.save()
    }

    public func removeQueue(named name: String) throws {
        guard CategoryKind.canRemove(categoryNamed: name) else {
            throw LibraryError.categoryCannotBeRemoved(name)
        }
        modelContext.delete(try fetchCategory(named: name))
        try modelContext.save()
    }

    public func updateQueueOptions(_ options: QueueOptions, named name: String) throws {
        let category = try fetchCategory(named: name)
        category.startTimeEnabled = options.startTimeEnabled
        category.startTimeMinutes = options.startTime.minutesSinceMidnight
        category.endTimeEnabled = options.endTimeEnabled
        category.endTimeMinutes = options.endTime.minutesSinceMidnight
        category.isReversed = options.isReversed
        category.shutsDownAfterDownload = options.shutsDownAfterDownload
        try modelContext.save()
    }

    // MARK: Downloads

    public func addDownload(
        _ request: DownloadRequest,
        to categoryName: String,
        status: DownloadStatus,
        at date: Date
    ) throws -> GID {
        guard CategoryKind(categoryName: categoryName) != .allDownloads else {
            throw LibraryError.categoryNotAddable(categoryName)
        }
        let category = try fetchCategory(named: categoryName)
        let all = try modelContext.fetch(FetchDescriptor<DownloadRecord>())

        var generator = SystemRandomNumberGenerator()
        let gid = GID.generate(
            avoiding: Set(all.compactMap { GID(rawValue: $0.gid) }),
            using: &generator
        )

        let record = DownloadRecord(
            gid: gid.rawValue,
            categoryPosition: (category.downloads.map(\.categoryPosition).max() ?? -1) + 1,
            allDownloadsPosition: (all.map(\.allDownloadsPosition).max() ?? -1) + 1,
            statusRawValue: status.rawValue,
            date: date,
            link: request.link,
            customFileName: request.customFileName,
            folder: request.folder,
            connections: request.connections,
            speedDial: request.speedDial,
            startTimeMinutes: request.startTime?.minutesSinceMidnight,
            endTimeMinutes: request.endTime?.minutesSinceMidnight,
            proxyKindRawValue: request.proxy?.kind.rawValue,
            proxyHost: request.proxy?.host,
            proxyPort: request.proxy?.port,
            proxyUser: request.proxy?.user,
            httpUser: request.httpUser,
            referer: request.referer,
            userAgent: request.userAgent,
            headers: request.headers,
            cookieFilePath: request.cookieFilePath,
            shutsDownAfterDownload: request.shutsDownAfterDownload
        )
        modelContext.insert(record)
        record.category = category
        try modelContext.save()
        return gid
    }

    /// A Category's Downloads, newest first. All Downloads lists every Download.
    public func downloads(in categoryName: String) throws -> [DownloadSummary] {
        if CategoryKind(categoryName: categoryName) == .allDownloads {
            return try modelContext.fetch(FetchDescriptor<DownloadRecord>())
                .sorted { $0.allDownloadsPosition > $1.allDownloadsPosition }
                .map(summary(of:))
        }
        return try fetchCategory(named: categoryName).downloads
            .sorted { $0.categoryPosition > $1.categoryPosition }
            .map(summary(of:))
    }

    public func download(_ gid: GID) throws -> DownloadSummary? {
        try fetchDownload(gid).map(summary(of:))
    }

    public func containsLink(_ link: String) throws -> Bool {
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.link == link })
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }

    public func saveProgress(_ progress: DownloadProgress, for gid: GID) throws {
        guard let record = try fetchDownload(gid) else {
            throw LibraryError.downloadNotFound(gid)
        }
        record.statusRawValue = progress.status.rawValue
        record.fileName = progress.fileName
        record.totalBytes = progress.totalBytes
        record.downloadedBytes = progress.downloadedBytes
        try modelContext.save()
    }

    // MARK: Fetching

    private func fetchCategories() throws -> [CategoryRecord] {
        try modelContext.fetch(
            FetchDescriptor<CategoryRecord>(sortBy: [SortDescriptor(\.sidePanelPosition)])
        )
    }

    private func fetchCategory(named name: String) throws -> CategoryRecord {
        var descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        guard let category = try modelContext.fetch(descriptor).first else {
            throw LibraryError.categoryNotFound(name)
        }
        return category
    }

    private func fetchDownload(_ gid: GID) throws -> DownloadRecord? {
        let rawValue = gid.rawValue
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.gid == rawValue })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Mapping

    private func summary(of record: CategoryRecord) -> CategorySummary {
        var options = QueueOptions()
        options.startTimeEnabled = record.startTimeEnabled
        options.startTime = ClockTime(minutesSinceMidnight: record.startTimeMinutes) ?? options.startTime
        options.endTimeEnabled = record.endTimeEnabled
        options.endTime = ClockTime(minutesSinceMidnight: record.endTimeMinutes) ?? options.endTime
        options.isReversed = record.isReversed
        options.shutsDownAfterDownload = record.shutsDownAfterDownload
        return CategorySummary(
            name: record.name,
            kind: CategoryKind(categoryName: record.name),
            options: options
        )
    }

    private func summary(of record: DownloadRecord) -> DownloadSummary {
        var proxy: ProxySettings?
        if let kind = record.proxyKindRawValue.flatMap(ProxySettings.Kind.init(rawValue:)),
           let host = record.proxyHost,
           let port = record.proxyPort {
            proxy = ProxySettings(kind: kind, host: host, port: port, user: record.proxyUser)
        }
        let request = DownloadRequest(
            link: record.link,
            customFileName: record.customFileName,
            folder: record.folder,
            connections: record.connections,
            speedDial: record.speedDial,
            startTime: record.startTimeMinutes.flatMap(ClockTime.init(minutesSinceMidnight:)),
            endTime: record.endTimeMinutes.flatMap(ClockTime.init(minutesSinceMidnight:)),
            proxy: proxy,
            httpUser: record.httpUser,
            referer: record.referer,
            userAgent: record.userAgent,
            headers: record.headers,
            cookieFilePath: record.cookieFilePath,
            shutsDownAfterDownload: record.shutsDownAfterDownload
        )
        return DownloadSummary(
            gid: GID(rawValue: record.gid)!,
            request: request,
            status: DownloadStatus(rawValue: record.statusRawValue) ?? .stopped,
            category: record.category?.name ?? "",
            fileName: record.fileName,
            totalBytes: record.totalBytes,
            downloadedBytes: record.downloadedBytes,
            firstTryDate: record.firstTryDate,
            lastTryDate: record.lastTryDate
        )
    }
}
