#!/bin/bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:/Users/rui/flutter/bin:$PATH"
export ANDROID_USER_HOME="$PWD/.android_user_home"
mkdir -p "$ANDROID_USER_HOME"
flutter build apk --debug --target-platform android-arm64
