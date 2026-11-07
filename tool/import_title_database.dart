import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/import_title_database.dart INPUT.c OUTPUT.json',
    );
    exitCode = 64;
    return;
  }

  final input = File(arguments[0]);
  if (!input.existsSync()) {
    stderr.writeln('Input does not exist: ${input.path}');
    exitCode = 66;
    return;
  }

  final pattern = RegExp(
    r'^\s*\{0x([0-9A-Fa-f]{16})ULL,\s*"((?:[^"\\]|\\.)*)"\},\s*$',
  );
  final titles = <String, String>{};
  for (final line in input.readAsLinesSync()) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    final titleId = match.group(1)!.toUpperCase();
    final escapedName = match.group(2)!;
    final name = jsonDecode('"$escapedName"') as String;
    titles[titleId] = name;
  }
  if (titles.isEmpty) {
    stderr.writeln('No title entries were found in ${input.path}');
    exitCode = 65;
    return;
  }

  final sorted = Map<String, String>.fromEntries(
    titles.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key)),
  );
  final output = File(arguments[1]);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync('${jsonEncode(sorted)}\n');
  stdout.writeln('Wrote ${sorted.length} title names to ${output.path}');
}
