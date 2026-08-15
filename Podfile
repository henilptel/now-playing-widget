# PockKit's git-HEAD podspec requires 10.15 minimum.
platform :osx, '10.15'

target 'NowPlaying' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for NowPlaying
  # PockKit's CocoaPods trunk releases stop at 0.3.1 (Oct 2021) — later
  # API additions this source needs (e.g. PKWidgetPreference) only ever
  # landed on the git repo's main branch, never a numbered release.
  pod 'PockKit', :git => 'https://github.com/pock/pockkit.git'

end
