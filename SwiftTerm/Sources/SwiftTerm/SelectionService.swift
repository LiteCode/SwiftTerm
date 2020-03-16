//
//  SelectionService.swift
//  iOS
//
//  Created by Miguel de Icaza on 3/5/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

class SelectionService {
    var terminal: Terminal
    
    public init (terminal: Terminal)
    {
        self.terminal = terminal
        _active = false
        start = Position(col: 0, row: 0)
        end = Position(col: 0, row: 0)
    }
    
    /**
     * Controls whether the selection is active or not
     */
    var _active: Bool = false
    public var active: Bool {
        get {
            return _active
        }
        set(newValue) {
            let emit = newValue != _active
            _active = newValue
            if emit {
                terminal.tdel.selectionChanged (source: terminal)
            }
        }
    }
    
    /**
     * Returns the selection starting point in buffer coordinates
     */
    public private(set) var start: Position

    /**
     * Returns the selection ending point in buffer coordinates
     */
    public private(set) var end: Position
    
    /**
     * Starts the selection from the specific location
     */
    public func startSelection (row: Int, col: Int)
    {
        setSoftStart(row: row, col: col)
        active = true
    }
    
    /**
     * Starts selection, the range is determined by the last start position
     */
    public func startSelection ()
    {
        end = start
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from
     */
    public func setSoftStart (row: Int, col: Int)
    {
        let p = Position(col: col, row: row)
        start = p
        end = p
    }
    
    enum compareResult {
        case before
        case after
        case equal
    }
    // Compares two positions for ordering
    // -1 a comes before b
    //  1 a comes after b
    //  0 a and b are the same
    func compare (_ a: Position, _ b: Position) -> compareResult
    {
        if a.row < b.row { return .before }
        if a.row > b.row { return .after }
        // a and b are on the same row, compare columns
        if a.col < b.col { return .before }
        if a.col > b.col { return .after }
        return .equal
    }
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     */
    public func shiftExtend (row: Int, col: Int)
    {
        active = true
        let newEnd = Position  (col: col, row: row + terminal.buffer.yDisp)
        
        var shouldSwapStart = false
        if compare (start, end) == .before {
            // start is before end, is the new end before Start
            if compare (newEnd, start) == .before {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        } else if compare (start, end) == .after {
            if compare (newEnd, start) == .after {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        }
        
        if (shouldSwapStart) {
            start = end
        }
        
        end = newEnd
        terminal.tdel.selectionChanged(source: terminal)
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     */
    public func dragExtend (row: Int, col: Int)
    {
        end = Position(col: col, row: row+terminal.buffer.yDisp)
        terminal.tdel.selectionChanged(source: terminal)
    }
    
    /**
     * Selects the entire buffer
     */
    public func selectAll ()
    {
        start = Position(col: 0, row: 0)
        end = Position(col: terminal.cols-1, row: terminal.buffer.lines.maxLength - 1)
        active = true
    }
    
    /**
     * Clears the selection
     */
    public func selectNone ()
    {
        active = false
    }
    
    public func getSelectedText () -> String
    {
        let lines = getSelectedLines()
        if lines.count == 0 {
            return ""
        }
        var r = ""
        for line in lines {
            r += line.toString()
        }
        return r
    }
    
    func getSelectedLines() -> [Line]
    {
        var start = self.start
        var end = self.end
        
        switch compare (start, end) {
        case .equal:
            return []
        case .after:
            start = end
            end = start
        case .before:
            break
        }
        if start.row < 0 || start.row > terminal.buffer.lines.count {
            return []
        }
        
        if end.row >= terminal.buffer.lines.count {
            end.row = terminal.buffer.lines.count-1
        }
        return getSelectedLines(start, end)
    }
    
    func getSelectedLines(_ start: Position, _ end: Position) -> [Line]
    {
        var lines: [Line] = []
        var buffer = terminal.buffer
        var str = ""
        var currentLine = Line ()
        lines.append(currentLine)
        
        // keep a list of blank lines that we see. if we see content after a group
        // of blanks, add those blanks but skip all remaining / trailing blanks
        // these will be blank lines in the selected text output
        var blanks: [LineFragment] = []
        
        func addBlanks () {
            var lastLine = -1;
            for b in blanks {
                if lastLine != -1 && b.line != lastLine {
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                lastLine = b.line
                currentLine.add(fragment: b)
            }
            blanks = []
        };
        
        // get the first line
        var bufferLine = buffer.lines [start.row]
        if bufferLine.hasAnyContent() {
            let str: String = translateBufferLineToString (buffer: buffer, line: start.row, start: start.col, end: start.row < end.row ? -1 : end.col)
            
            let fragment = LineFragment (text: str, line: start.row, location: start.col, length: str.count)
            currentLine.add (fragment: fragment)
        }
        
        // get the middle rows
        var line = start.row + 1
        var isWrapped = false
        while line < end.row {
            bufferLine = buffer.lines [line]
            isWrapped = bufferLine.isWrapped
            
            str = translateBufferLineToString (buffer: buffer, line: line, start: 0, end: -1)
            
            if bufferLine.hasAnyContent () {
                // add previously gathered blank fragments
                addBlanks ()
                
                if !isWrapped {
                    // this line is not a wrapped line, so the
                    // prior line has a hard linefeed
                    // add a fragment to that line
                    currentLine.add (fragment: LineFragment.newLine (line: line - 1))
                    
                    // start a new line
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                // add the text we found to the current line
                currentLine.add (fragment: LineFragment (text: str, line: line, location: 0, length: str.count))
            } else {
                // this line has no content, which means that it's a blank line inserted
                // somehow, or one of the trailing blank lines after the last actual content
                // make a note of the line
                // check that this line is a wrapped line, if so, add a line feed fragment
                if !isWrapped {
                    blanks.append (LineFragment.newLine (line: line - 1))
                }
                
                blanks.append(LineFragment (text: str, line: line, location: 0, length: str.count));
            }
            
            line += 1
        }
        
        // get the last row
        if end.row != start.row {
            bufferLine = buffer.lines [end.row]
            if bufferLine.hasAnyContent () {
                addBlanks ()
                
                isWrapped = bufferLine.isWrapped
                str = translateBufferLineToString (buffer: buffer, line: end.row, start: 0, end: end.col)
                if !isWrapped {
                    currentLine.add(fragment: LineFragment.newLine (line: line - 1))
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                currentLine.add (fragment: LineFragment (text: str, line: line, location: 0, length: str.count))
            }
        }
        return lines
    }

    func translateBufferLineToString (buffer: Buffer, line: Int, start: Int, end: Int) -> String
    {
        buffer.translateBufferLineToString(lineIndex: line, trimRight: true, startCol: start, endCol: end).replacingOccurrences(of: "\u{0}", with: " ")
    }
}