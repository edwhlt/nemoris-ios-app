cd /Users/edwin/_dev/NEMORIS/NemorisApp

echo
echo "==================== HAPTIC ===================="
grep -n "HapticService.swift" Nemoris.xcodeproj/project.pbxproj

echo
echo "==================== TRANSACTION DENSITY ===================="
grep -n "TransactionDensity.swift" Nemoris.xcodeproj/project.pbxproj

echo
echo "==================== UUID HAPTIC ===================="
grep -n "E9E9E9F300000000ABCDABCD" Nemoris.xcodeproj/project.pbxproj

echo
echo "==================== UUID TRANSACTION ===================="
grep -n "E9E9E9F500000000ABCDABCD" Nemoris.xcodeproj/project.pbxproj

echo
echo "==================== PBXFILESYSTEM ===================="
grep -n "PBXFileSystem" -A50 -B20 Nemoris.xcodeproj/project.pbxproj