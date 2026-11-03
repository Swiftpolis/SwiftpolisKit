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
        // Nothing is muxing yet, so one that was has been cut off and needs another go.
        for pair in try modelContext.fetch(FetchDescriptor<VideoPairRecord>())
        where pair.muxingStatusRawValue == MuxingStatus.muxing.rawValue {
            pair.muxingStatusRawValue = MuxingStatus.error.rawValue
        }
        try modelContext.save()
    }

    /// iOS moves an app's folders when it updates the app, so saved paths have to follow.
    public func moveSavedPaths(from oldFolder: String, to newFolder: String) throws {
        func moved(_ path: String) -> String? {
            path == oldFolder || path.hasPrefix(oldFolder + "/") ? newFolder + path.dropFirst(oldFolder.count) : nil
        }
        for download in try modelContext.fetch(FetchDescriptor<DownloadRecord>()) {
            if let folder = moved(download.folder) { download.folder = folder }
            if let filePath = download.filePath.flatMap(moved) { download.filePath = filePath }
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
        let category = try fetchCategory(named: name)
        try deletePairs(containing: Set(category.downloads.map(\.gid)))
        modelContext.delete(category)
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
            shutsDownAfterDownload: request.shutsDownAfterDownload,
            engineKindRawValue: request.engine.rawValue
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
        let record = try requireDownload(gid)
        record.statusRawValue = progress.status.rawValue
        if let fileName = progress.fileName { record.fileName = fileName }
        if let totalBytes = progress.totalBytes { record.totalBytes = totalBytes }
        record.downloadedBytes = progress.downloadedBytes
        if let filePath = progress.filePath { record.filePath = filePath }
        try modelContext.save()
    }

    /// Records that a finished file has moved.
    public func updateFilePath(_ path: String, for gid: GID) throws {
        try requireDownload(gid).filePath = path
        try modelContext.save()
    }

    /// Clears a finished Download's schedule, as Persepolis does when one ends.
    public func clearSchedule(of gid: GID) throws {
        let record = try requireDownload(gid)
        record.startTimeMinutes = nil
        record.endTimeMinutes = nil
        record.shutsDownAfterDownload = false
        try modelContext.save()
    }

    public func recordStart(of gid: GID, status: DownloadStatus, at date: Date) throws {
        let record = try requireDownload(gid)
        record.statusRawValue = status.rawValue
        record.lastTryDate = date
        try modelContext.save()
    }

    /// Fills in what the Spider learned. A name the user chose always stays.
    public func saveSpiderFindings(fileName: String?, totalBytes: Int64?, for gid: GID) throws {
        let record = try requireDownload(gid)
        if record.customFileName == nil, let fileName { record.fileName = fileName }
        if let totalBytes { record.totalBytes = totalBytes }
        try modelContext.save()
    }

    public func updateRequest(_ request: DownloadRequest, for gid: GID) throws {
        let record = try requireDownload(gid)
        record.link = request.link
        record.customFileName = request.customFileName
        if let name = request.customFileName { record.fileName = name }
        record.folder = request.folder
        record.connections = request.connections
        record.speedDial = request.speedDial
        record.startTimeMinutes = request.startTime?.minutesSinceMidnight
        record.endTimeMinutes = request.endTime?.minutesSinceMidnight
        record.proxyKindRawValue = request.proxy?.kind.rawValue
        record.proxyHost = request.proxy?.host
        record.proxyPort = request.proxy?.port
        record.proxyUser = request.proxy?.user
        record.httpUser = request.httpUser
        record.referer = request.referer
        record.userAgent = request.userAgent
        record.headers = request.headers
        record.cookieFilePath = request.cookieFilePath
        record.shutsDownAfterDownload = request.shutsDownAfterDownload
        record.engineKindRawValue = request.engine.rawValue
        try modelContext.save()
    }

    public func removeDownloads(_ gids: [GID]) throws {
        for gid in gids {
            if let record = try fetchDownload(gid) { modelContext.delete(record) }
        }
        try deletePairs(containing: Set(gids.map(\.rawValue)))
        try modelContext.save()
    }

    /// Empties the list. As in Persepolis, this also removes user-created Queues.
    public func clearList() throws {
        for download in try modelContext.fetch(FetchDescriptor<DownloadRecord>()) {
            modelContext.delete(download)
        }
        for pair in try modelContext.fetch(FetchDescriptor<VideoPairRecord>()) {
            modelContext.delete(pair)
        }
        for category in try fetchCategories() where CategoryKind.canRemove(categoryNamed: category.name) {
            modelContext.delete(category)
        }
        try modelContext.save()
    }

    /// Moves a stopped Download to the end of another Category. Its schedule doesn't go with it.
    public func moveDownload(_ gid: GID, to categoryName: String) throws {
        guard CategoryKind(categoryName: categoryName) != .allDownloads else {
            throw LibraryError.categoryNotAddable(categoryName)
        }
        let record = try requireDownload(gid)
        let status = DownloadStatus(rawValue: record.statusRawValue) ?? .stopped
        guard status.canChangeCategory else { throw LibraryError.downloadIsActive(gid) }

        let category = try fetchCategory(named: categoryName)
        guard record.category?.name != categoryName else { return }
        record.categoryPosition = (category.downloads.map(\.categoryPosition).max() ?? -1) + 1
        record.category = category
        record.startTimeMinutes = nil
        record.endTimeMinutes = nil
        record.shutsDownAfterDownload = false
        try modelContext.save()
    }

    /// Moves Downloads one place along a Queue's list. Selected ones stay together and in order, and
    /// a selection already at the end stays where it is.
    public func move(_ gids: [GID], in categoryName: String, direction: MoveDirection) throws {
        let selected = Set(gids.map(\.rawValue))
        var records = try fetchCategory(named: categoryName).downloads
            .sorted { $0.categoryPosition > $1.categoryPosition }
        let positions = records.map(\.categoryPosition)

        let indices = direction == .up ? Array(records.indices) : Array(records.indices.reversed())
        let offset = direction == .up ? -1 : 1
        for index in indices where selected.contains(records[index].gid) {
            let neighbour = index + offset
            guard records.indices.contains(neighbour), !selected.contains(records[neighbour].gid) else { continue }
            records.swapAt(index, neighbour)
        }

        for (record, position) in zip(records, positions) {
            record.categoryPosition = position
        }
        try modelContext.save()
    }

    /// Sorts a list and saves the order, so that a Queue also runs in this order.
    public func sort(_ categoryName: String, by key: DownloadSortKey) throws {
        let isAllDownloads = CategoryKind(categoryName: categoryName) == .allDownloads
        let records = isAllDownloads
            ? try modelContext.fetch(FetchDescriptor<DownloadRecord>())
                .sorted { $0.allDownloadsPosition > $1.allDownloadsPosition }
            : try fetchCategory(named: categoryName).downloads
                .sorted { $0.categoryPosition > $1.categoryPosition }

        let sorted = key.sorted(records) { record in
            DownloadSortFields(
                fileName: record.fileName,
                status: DownloadStatus(rawValue: record.statusRawValue) ?? .stopped,
                totalBytes: record.totalBytes,
                firstTry: record.firstTryDate,
                lastTry: record.lastTryDate
            )
        }
        for (index, record) in sorted.enumerated() {
            let position = sorted.count - index
            if isAllDownloads {
                record.allDownloadsPosition = position
            } else {
                record.categoryPosition = position
            }
        }
        try modelContext.save()
    }

    // MARK: Video pairs

    /// Adds both streams, the video first. Only the video can start right away, so the audio stream
    /// always begins stopped.
    public func addVideoPair(
        video: DownloadRequest,
        audio: DownloadRequest,
        to categoryName: String,
        videoStatus: DownloadStatus,
        at date: Date
    ) throws -> VideoPair {
        let videoGID = try addDownload(video, to: categoryName, status: videoStatus, at: date)
        let audioGID = try addDownload(audio, to: categoryName, status: .stopped, at: date)
        modelContext.insert(VideoPairRecord(videoGID: videoGID.rawValue, audioGID: audioGID.rawValue))
        try modelContext.save()
        return VideoPair(videoGID: videoGID, audioGID: audioGID, muxingStatus: .notStarted)
    }

    public func videoPairs() throws -> [VideoPair] {
        try modelContext.fetch(FetchDescriptor<VideoPairRecord>()).compactMap(pair(from:))
    }

    public func videoPair(containing gid: GID) throws -> VideoPair? {
        try fetchPair(containing: gid.rawValue).flatMap(pair(from:))
    }

    public func setMuxingStatus(_ status: MuxingStatus, for pair: VideoPair) throws {
        try fetchPair(containing: pair.videoGID.rawValue)?.muxingStatusRawValue = status.rawValue
        try modelContext.save()
    }

    /// Muxing worked, so the audio stream's row goes, and the video's becomes the finished file.
    public func finishVideoPair(_ pair: VideoPair, fileName: String, filePath: String, bytes: Int64) throws {
        let video = try requireDownload(pair.videoGID)
        video.statusRawValue = DownloadStatus.complete.rawValue
        video.fileName = fileName
        video.customFileName = fileName
        video.filePath = filePath
        video.totalBytes = bytes
        video.downloadedBytes = bytes
        try removeDownloads([pair.audioGID])
        if let record = try fetchPair(containing: pair.videoGID.rawValue) { modelContext.delete(record) }
        try modelContext.save()
    }

    private func fetchPair(containing gid: String) throws -> VideoPairRecord? {
        var descriptor = FetchDescriptor<VideoPairRecord>(
            predicate: #Predicate { $0.videoGID == gid || $0.audioGID == gid }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func deletePairs(containing gids: Set<String>) throws {
        for pair in try modelContext.fetch(FetchDescriptor<VideoPairRecord>())
        where gids.contains(pair.videoGID) || gids.contains(pair.audioGID) {
            modelContext.delete(pair)
        }
    }

    private func pair(from record: VideoPairRecord) -> VideoPair? {
        guard let video = GID(rawValue: record.videoGID), let audio = GID(rawValue: record.audioGID) else { return nil }
        return VideoPair(
            videoGID: video,
            audioGID: audio,
            muxingStatus: MuxingStatus(rawValue: record.muxingStatusRawValue) ?? .notStarted
        )
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

    private func requireDownload(_ gid: GID) throws -> DownloadRecord {
        guard let record = try fetchDownload(gid) else { throw LibraryError.downloadNotFound(gid) }
        return record
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
            shutsDownAfterDownload: record.shutsDownAfterDownload,
            engine: DownloadEngineKind(rawValue: record.engineKindRawValue) ?? .http
        )
        return DownloadSummary(
            gid: GID(rawValue: record.gid)!,
            request: request,
            status: DownloadStatus(rawValue: record.statusRawValue) ?? .stopped,
            category: record.category?.name ?? "",
            fileName: record.fileName,
            filePath: record.filePath,
            totalBytes: record.totalBytes,
            downloadedBytes: record.downloadedBytes,
            firstTryDate: record.firstTryDate,
            lastTryDate: record.lastTryDate
        )
    }
}
