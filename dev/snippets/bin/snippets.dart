// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show ProcessResult, exitCode, stderr;

import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as path;
import 'package:platform/platform.dart';
import 'package:process/process.dart';
import 'package:snippets/snippets.dart';

const String _kElementOption = 'element';
const String _kFormatOutputOption = 'format-output';
const String _kHelpOption = 'help';
const String _kInputOption = 'input';
const String _kLibraryOption = 'library';
const String _kOutputDirectoryOption = 'output-directory';
const String _kOutputOption = 'output';
const String _kPackageOption = 'package';
const String _kSerialOption = 'serial';
const String _kTemplateOption = 'template';
const String _kTypeOption = 'type';

class GitStatusFailed implements Exception {
  GitStatusFailed(this.gitResult);

  final ProcessResult gitResult;

  @override
  String toString() {
    return 'git status exited with a non-zero exit code: '
        '${gitResult.exitCode}:\n${gitResult.stderr}\n${gitResult.stdout}';
  }
}

/// A singleton filesystem that can be set by tests to a memory filesystem.
FileSystem filesystem = const LocalFileSystem();

/// A singleton snippet generator that can be set by tests to a mock, so that
/// we can test the command line parsing.
SnippetGenerator snippetGenerator = SnippetGenerator();

/// A singleton platform that can be set by tests for use in testing command line
/// parsing.
Platform platform = const LocalPlatform();

/// A singleton process manager that can be set by tests for use in testing.
ProcessManager processManager = const LocalProcessManager();

/// Get the name of the channel these docs are from.
///
/// First check env variable LUCI_BRANCH, then refer to the currently
/// checked out git branch.
String getChannelName({
  Platform platform = const LocalPlatform(),
  ProcessManager processManager = const LocalProcessManager(),
}) {
  final String? envReleaseChannel = platform.environment['LUCI_BRANCH']?.trim();
  if (<String>['master', 'stable', 'main'].contains(envReleaseChannel)) {
    // Backward compatibility: Still support running on "master", but pretend it is "main".
    if (envReleaseChannel == 'master') {
      return 'main';
    }
    return envReleaseChannel!;
  }

  final RegExp gitBranchRegexp = RegExp(r'^## (?<branch>.*)');
  final ProcessResult gitResult = processManager.runSync(
      <String>['git', 'status', '-b', '--porcelain'],
      // Use the FLUTTER_ROOT, if defined.
      workingDirectory: platform.environment['FLUTTER_ROOT']?.trim() ??
          filesystem.currentDirectory.path,
      // Adding extra debugging output to help debug why git status inexplicably fails
      // (random non-zero error code) about 2% of the time.
      environment: <String, String>{'GIT_TRACE': '2', 'GIT_TRACE_SETUP': '2'});
  if (gitResult.exitCode != 0) {
    throw GitStatusFailed(gitResult);
  }

  final RegExpMatch? gitBranchMatch = gitBranchRegexp
      .firstMatch((gitResult.stdout as String).trim().split('\n').first);
  return gitBranchMatch == null
      ? '<unknown>'
      : gitBranchMatch.namedGroup('branch')!.split('...').first;
}

const List<String> sampleTypes = <String>[
  'snippet',
  'sample',
  'dartpad',
];

// This is a hack to workaround the fact that git status inexplicably fails
// (with random non-zero error code) about 2% of the time.
String getChannelNameWithRetries({
  Platform platform = const LocalPlatform(),
  ProcessManager processManager = const LocalProcessManager(),
}) {
  int retryCount = 0;

  while (retryCount < 2) {
    try {
      return getChannelName(platform: platform, processManager: processManager);
    } on GitStatusFailed catch (e) {
      retryCount += 1;
      stderr.write(
          'git status failed, retrying ($retryCount)\nError report:\n$e');
    }
  }

  return getChannelName(platform: platform, processManager: processManager);
}

/// Generates snippet dartdoc output for a given input, and creates any sample
/// applications needed by the snippet.
void main(List<String> argList) {
  final Map<String, String> environment = platform.environment;
  final ArgParser parser = ArgParser();

  parser.addOption(
    _kTypeOption,
    defaultsTo: 'dartpad',
    allowed: sampleTypes,
    allowedHelp: <String, String>{
      'dartpad':
          'Produce a code sample application complete with embedding the sample in an '
              'application template for using in Dartpad.',
      'sample':
          'Produce a code sample application complete with embedding the sample in an '
              'application template.',
      'snippet':
          'Produce a nicely formatted piece of sample code. Does not embed the '
              'sample into an application template.',
    },
    help: 'The type of snippet to produce.',
  );
  // TODO(goderbauer): Remove template support, this is no longer used.
  parser.addOption(
    _kTemplateOption,
    help: 'The name of the template to inject the code into.',
  );
  parser.addOption(
    _kOutputOption,
    help: 'The output name for the generated sample application. Overrides '
        'the naming generated by the --$_kPackageOption/--$_kLibraryOption/--$_kElementOption '
        'arguments. Metadata will be written alongside in a .json file. '
        'The basename of this argument is used as the ID. If this is a '
        'relative path, will be placed under the --$_kOutputDirectoryOption location.',
  );
  parser.addOption(
    _kOutputDirectoryOption,
    defaultsTo: '.',
    help: 'The output path for the generated sample application.',
  );
  parser.addOption(
    _kInputOption,
    defaultsTo: environment['INPUT'],
    help: 'The input file containing the sample code to inject.',
  );
  parser.addOption(
    _kPackageOption,
    defaultsTo: environment['PACKAGE_NAME'],
    help: 'The name of the package that this sample belongs to.',
  );
  parser.addOption(
    _kLibraryOption,
    defaultsTo: environment['LIBRARY_NAME'],
    help: 'The name of the library that this sample belongs to.',
  );
  parser.addOption(
    _kElementOption,
    defaultsTo: environment['ELEMENT_NAME'],
    help: 'The name of the element that this sample belongs to.',
  );
  parser.addOption(
    _kSerialOption,
    defaultsTo: environment['INVOCATION_INDEX'],
    help: 'A unique serial number for this snippet tool invocation.',
  );
  parser.addFlag(
    _kFormatOutputOption,
    defaultsTo: true,
    help: 'Applies the Dart formatter to the published/extracted sample code.',
  );
  parser.addFlag(
    _kHelpOption,
    negatable: false,
    help: 'Prints help documentation for this command',
  );

  final ArgResults args = parser.parse(argList);

  if (args[_kHelpOption]! as bool) {
    stderr.writeln(parser.usage);
    exitCode = 0;
    return;
  }

  final String sampleType = args[_kTypeOption]! as String;

  if (args[_kInputOption] == null) {
    stderr.writeln(parser.usage);
    errorExit(
        'The --$_kInputOption option must be specified, either on the command '
        'line, or in the INPUT environment variable.');
    return;
  }

  final File input = filesystem.file(args['input']! as String);
  if (!input.existsSync()) {
    errorExit('The input file ${input.path} does not exist.');
    return;
  }

  final bool formatOutput = args[_kFormatOutputOption]! as bool;
  final String packageName = args[_kPackageOption] as String? ?? '';
  final String libraryName = args[_kLibraryOption] as String? ?? '';
  final String elementName = args[_kElementOption] as String? ?? '';
  final String serial = args[_kSerialOption] as String? ?? '';
  late String id;
  File? output;
  final Directory outputDirectory =
      filesystem.directory(args[_kOutputDirectoryOption]! as String).absolute;

  if (args[_kOutputOption] != null) {
    id = path.basenameWithoutExtension(args[_kOutputOption]! as String);
    final File outputPath = filesystem.file(args[_kOutputOption]! as String);
    if (outputPath.isAbsolute) {
      output = outputPath;
    } else {
      output =
          filesystem.file(path.join(outputDirectory.path, outputPath.path));
    }
  } else {
    final List<String> idParts = <String>[];
    if (packageName.isNotEmpty && packageName != 'flutter') {
      idParts.add(packageName.replaceAll(RegExp(r'\W'), '_').toLowerCase());
    }
    if (libraryName.isNotEmpty) {
      idParts.add(libraryName.replaceAll(RegExp(r'\W'), '_').toLowerCase());
    }
    if (elementName.isNotEmpty) {
      idParts.add(elementName);
    }
    if (serial.isNotEmpty) {
      idParts.add(serial);
    }
    if (idParts.isEmpty) {
      errorExit('Unable to determine ID. At least one of --$_kPackageOption, '
          '--$_kLibraryOption, --$_kElementOption, -$_kSerialOption, or the environment variables '
          'PACKAGE_NAME, LIBRARY_NAME, ELEMENT_NAME, or INVOCATION_INDEX must be non-empty.');
      return;
    }
    id = idParts.join('.');
    output = outputDirectory.childFile('$id.dart');
  }
  output.parent.createSync(recursive: true);

  final int? sourceLine = environment['SOURCE_LINE'] != null
      ? int.tryParse(environment['SOURCE_LINE']!)
      : null;
  final String sourcePath = environment['SOURCE_PATH'] ?? 'unknown.dart';
  final SnippetDartdocParser sampleParser = SnippetDartdocParser(filesystem);
  final SourceElement element = sampleParser.parseFromDartdocToolFile(
    input,
    startLine: sourceLine,
    element: elementName,
    sourceFile: filesystem.file(sourcePath),
    type: sampleType,
  );
  final Map<String, Object?> metadata = <String, Object?>{
    'channel': getChannelNameWithRetries(
        platform: platform, processManager: processManager),
    'serial': serial,
    'id': id,
    'package': packageName,
    'library': libraryName,
    'element': elementName,
  };

  for (final CodeSample sample in element.samples) {
    sample.metadata.addAll(metadata);
    snippetGenerator.generateCode(
      sample,
      output: output,
      formatOutput: formatOutput,
    );
    print(snippetGenerator.generateHtml(sample));
  }

  exitCode = 0;
}