#!/bin/sh
# Runs grouped checks with synthetic data; never connects to a band or iPhone.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .private
cmake_bin="${CMAKE_BIN:-cmake}"
python_bin="${PYTHON_BIN:-.private/tools/mitmproxy-grpc/bin/python}"
if ! "$python_bin" -c 'import mitmproxy' 2>/dev/null; then
    echo "Set PYTHON_BIN to a Python 3.12+ environment with mitmproxy==12.2.3 (see README)." >&2
    exit 1
fi
"$cmake_bin" -S Native -B .private/native-tests -DAIR_BUILD_TESTS=ON > .private/check-native.log 2>&1
"$cmake_bin" --build .private/native-tests --parallel 2 >> .private/check-native.log 2>&1
.private/native-tests/air-transport-test
swiftc App/Alarms.swift App/BandMetrics.swift tests/AlarmParserTests.swift -o .private/alarm-parser-tests
.private/alarm-parser-tests
swiftc App/DeviceKeys.swift tests/DeviceKeysTests.swift -o .private/device-keys-tests
.private/device-keys-tests
swiftc App/Fitness.swift App/Alerts.swift tests/FitnessTests.swift -o .private/fitness-tests
.private/fitness-tests
swiftc App/Fitness.swift App/Alerts.swift App/AppStore.swift tests/StoreTests.swift -o .private/store-tests
.private/store-tests
"$python_bin" -m unittest discover -s tests -q
