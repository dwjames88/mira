import MiraCore

extension EditorModel {
    /// Paper (a print stock after the film) is offered for every film except the print cards themselves.
    public var showsPaperChips: Bool { selectedFilm.map { $0.family != .print } ?? false }

    /// Chooses a scan profile. Scan and Paper are mutually exclusive: a scan other than Neutral clears the paper.
    public func selectScan(_ scan: ScanProfile) {
        recipe.scanProfile = scan
        if scan != .neutral { recipe.paper = .none }
    }

    /// Chooses a print stock. A paper other than None resets the scan to Neutral.
    public func selectPaper(_ paper: PaperProfile) {
        recipe.paper = paper
        if paper != .none { recipe.scanProfile = .neutral }
    }
}
