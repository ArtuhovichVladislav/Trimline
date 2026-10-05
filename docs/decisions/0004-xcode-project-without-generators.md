# 0004. Xcode project without generators

**Decision.** `Trimline.xcodeproj` uses folders synchronized with the file system (Xcode 16+): new files in
`Trimline/` join the target without editing the project. The logic lives in the local `TrimlineCore` package,
which builds and tests with `swift test` without the app.

**Why.** The project file hardly ever changes, there are fewer conflicts in pull requests, and there is no
dependency on XcodeGen or Tuist.
