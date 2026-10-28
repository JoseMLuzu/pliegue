# Native macOS Interface

Pliegue uses standard SwiftUI macOS components rather than a custom branded canvas. The window follows system appearance, accent color, text styles, and control behavior. No light color scheme is forced.

## Window Structure

- A `NavigationSplitView` provides a standard collapsible sidebar with Photos, Video, Audio, 3D models, and Files & Folders.
- A unified system toolbar contains Add, Remove, Compress/Stop, Save Result, and an inspector toggle. Commands expose tooltips and retain their menu shortcuts.
- The main content is a native file table with Name, Kind, and Size columns, system file icons, multiple selection, context-menu removal, and Delete-key support. The empty state uses `ContentUnavailableView` with Add Files and Add Folder actions.
- A native collapsible inspector contains grouped forms for compression settings, selection information, results, and supported formats. Native popup pickers control fidelity and quality. GLB whitespace optimization does not show irrelevant ZIP effort controls.
- A compact bottom area shows operation progress, errors, and the actual result. It remains visible while the table scrolls. The status bar shows item count, input size, and local-processing information.
- Progress and result values come from actual operations. Original-retained results expose Show in Finder; accepted results expose Save and, once saved, Show in Finder.

The minimum window size is 840 × 520 points; the default is 1000 × 640. Sidebar and inspector widths use system split-view behavior. The toolbar and title bar are managed by macOS.

## Files, Menus, and Appearance

SwiftUI's system file importer presents separate Add Files and Add Folder workflows. Finder drops accept both. Security-scoped access and validation remain owned by the compression model. Saving continues to use a native asynchronous save sheet and safe destination staging.

Command-O adds files, Shift-Command-O adds folders, Command-Return compresses, Command-period cancels, and Command-S saves an accepted result. Removing a row only removes it from the app's list; it does not delete the source. Toolbar and menu availability follows the current operation state.

System colors support light and dark appearance. Native lists, tables, forms, controls, focus behavior, selection, and accessibility replace custom button styles, illustrations, marketing headings, and oversized result cards. All interface copy, documentation, and source comments are in English. Compression limits and lossy choices remain visible in the inspector and help sheet.

## References

The layout follows Apple's guidance on [designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) and uses the native [SwiftUI inspector](https://developer.apple.com/videos/play/wwdc2023/10161/) in the split view's detail column.
