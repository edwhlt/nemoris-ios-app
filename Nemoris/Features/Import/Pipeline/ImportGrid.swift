import Foundation

/// A table of raw values: headers + rows of cells.
///
/// PURE engine. It's the COMMON output format of tabular sources — CSV, TSV
/// and XLSX workbooks — precisely because they all ask the user the same
/// question: "which column is the date, which one the amount, which one the
/// label?".
///
/// Converging XLSX here, rather than writing it its own mapping screen, keeps
/// a single mapping path instead of one per format, each with its own
/// separator detection and decimal convention.
struct ImportGrid: Equatable, Codable, Hashable, Sendable {
    /// Column names. Synthetic ("Column 1") when the source has no recognizable
    /// header row.
    var headers: [String]
    /// True when the first row was recognized as a header and is therefore NOT data.
    var hasExplicitHeader: Bool
    /// The data rows, without the header.
    var rows: [[String]]
    /// Separator kept for a text source. Empty for a workbook, whose cells are
    /// already delimited by the format.
    var separator: String
    /// Sheet name, for a multi-sheet workbook.
    var sheetName: String?

    init(headers: [String], hasExplicitHeader: Bool, rows: [[String]],
         separator: String = "", sheetName: String? = nil) {
        self.headers = headers
        self.hasExplicitHeader = hasExplicitHeader
        self.rows = rows
        self.separator = separator
        self.sheetName = sheetName
    }

    /// True when the table has enough structure for a column mapping to make
    /// sense.
    ///
    /// A source with ONE single column isn't a table: it's a prose statement.
    /// Sending it to the mapping screen would ask the user to designate columns
    /// that don't exist — it goes to the document parser instead.
    var isTabular: Bool { !rows.isEmpty && headers.count >= 2 }
}
