# bashcov + SimpleCov config — LINE coverage only.
# Branch coverage is Ruby-only in SimpleCov (see coverage-gate.sh §R3-gaps / AC9);
# for bash the report declares branch=n/a, NOT 0%.
# Requires: gem install simplecov simplecov-lcov bashcov
require "simplecov-lcov"
SimpleCov::Formatter::LcovFormatter.config.report_with_single_file = true
SimpleCov.formatter = SimpleCov::Formatter::LcovFormatter
SimpleCov.start
