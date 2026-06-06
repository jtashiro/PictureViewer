cd ~/dev/PictureViewer

xcodebuild clean archive \
  -project PictureViewer.xcodeproj \
  -scheme PictureViewer \
  -configuration Release \
  -archivePath ./build/PictureViewer.xcarchive && \
xcodebuild -exportArchive \
  -archivePath ./build/PictureViewer.xcarchive \
  -exportPath ./build \
  -exportOptionsPlist ExportOptions.plist && \
cp -R ./build/PictureViewer.app /Applications/ && \
echo "✅ PictureViewer installed in /Applications (unsigned)"
