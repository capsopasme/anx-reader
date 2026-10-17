import 'package:anx_reader/widgets/markdown/selection_control.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// A custom Markdown widget with theme-aware styling.
/// This widget provides better contrast and readability in both light and dark modes,
/// especially for blockquotes and code blocks that appear in AI chat responses.
///
/// Performance: `GptMarkdown` re-parses its whole source and lays it out as a
/// single rich text on every change. For a streaming AI reply that means the
/// cost of each update grows with the length of the reply. This widget splits
/// the source at blank lines into independent blocks and reuses the widget
/// instance of every block whose text did not change, so while a reply is
/// streaming only the last (still growing) block is parsed and laid out again.
class StyledMarkdown extends StatefulWidget {
  final String data;
  final bool selectable;
  final double? fontSize;

  const StyledMarkdown({
    super.key,
    required this.data,
    this.selectable = true,
    this.fontSize,
  });

  @override
  State<StyledMarkdown> createState() => _StyledMarkdownState();
}

class _StyledMarkdownState extends State<StyledMarkdown> {
  String? _builtData;
  double? _builtFontSize;
  List<String> _blocks = const [];
  List<Widget> _blockWidgets = const [];
  Widget? _gap;

  void _sync() {
    final fontSizeChanged = _builtFontSize != widget.fontSize;
    if (!fontSizeChanged && _builtData == widget.data) return;

    final blocks = splitMarkdownBlocks(widget.data);
    final widgets = List<Widget>.generate(blocks.length, (i) {
      if (!fontSizeChanged &&
          i < _blocks.length &&
          _blocks[i] == blocks[i]) {
        // Identical instance: Flutter skips rebuilding and re-laying it out.
        return _blockWidgets[i];
      }
      return _MarkdownBlock(
        key: ValueKey<int>(i),
        data: blocks[i],
        fontSize: widget.fontSize,
      );
    }, growable: false);

    if (fontSizeChanged || _gap == null) {
      // GptMarkdown renders a blank line between paragraphs as one empty
      // line of the base text style; an empty Text has exactly that height.
      _gap = Text(
        '',
        style: widget.fontSize != null
            ? TextStyle(fontSize: widget.fontSize)
            : null,
      );
    }

    _builtData = widget.data;
    _builtFontSize = widget.fontSize;
    _blocks = blocks;
    _blockWidgets = widgets;
  }

  @override
  Widget build(BuildContext context) {
    _sync();

    final Widget content;
    if (_blockWidgets.length == 1) {
      content = _blockWidgets.first;
    } else {
      final children = <Widget>[];
      for (var i = 0; i < _blockWidgets.length; i++) {
        if (i > 0) children.add(_gap!);
        children.add(_blockWidgets[i]);
      }
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    if (!widget.selectable) return content;
    return SelectableRegion(
      selectionControls: selectionControls(),
      child: content,
    );
  }
}

class _MarkdownBlock extends StatelessWidget {
  const _MarkdownBlock({
    super.key,
    required this.data,
    this.fontSize,
  });

  final String data;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GptMarkdown(data,
        followLinkColor: true,
        style: fontSize != null ? TextStyle(fontSize: fontSize) : null,
        onLinkTap: (href, text) =>
            launchUrlString(href, mode: LaunchMode.externalApplication),
        linkBuilder: (context, text, url, style) => Text.rich(
              text,
              style: style.copyWith(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ));
  }
}

final RegExp _fenceRegex = RegExp(r'^\s*(```|~~~)');

/// Splits markdown into blocks separated by blank lines.
///
/// A blank line is only treated as a boundary when it is outside fenced code
/// and display maths (`$$ … $$`, `\[ … \]`), and when the next block does not
/// start with indentation (an indented line continues the previous block, e.g.
/// a nested list item, and `GptMarkdown` would lose its indent once trimmed).
List<String> splitMarkdownBlocks(String source) {
  final text = source.trim();
  if (text.isEmpty) return const [''];
  if (!text.contains('\n\n') && !text.contains('\n\r\n')) return [text];

  final lines = text.split('\n');
  final blocks = <String>[];
  final current = <String>[];
  String? fence;
  var inDollarMath = false;
  var inBracketMath = false;
  var pendingBlank = false;

  void flush() {
    if (current.isNotEmpty) {
      blocks.add(current.join('\n'));
      current.clear();
    }
  }

  for (final line in lines) {
    final isBlank = line.trim().isEmpty;
    final inside = fence != null || inDollarMath || inBracketMath;

    if (isBlank && !inside) {
      pendingBlank = true;
      continue;
    }

    if (pendingBlank) {
      final startsIndented = line.startsWith(' ') || line.startsWith('\t');
      if (startsIndented) {
        // Keep the blank line(s) inside this block.
        current.add('');
      } else {
        flush();
      }
      pendingBlank = false;
    }
    current.add(line);

    final fenceMatch = _fenceRegex.firstMatch(line);
    if (fenceMatch != null) {
      final marker = fenceMatch.group(1)!;
      if (fence == null) {
        fence = marker;
      } else if (fence == marker) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;

    final dollarPairs = r'$$'.allMatches(line).length;
    if (dollarPairs.isOdd) inDollarMath = !inDollarMath;
    if (!inDollarMath) {
      final opens = r'\['.allMatches(line).length;
      final closes = r'\]'.allMatches(line).length;
      if (opens > closes) {
        inBracketMath = true;
      } else if (closes > opens) {
        inBracketMath = false;
      }
    }
  }
  flush();
  return blocks.isEmpty ? const [''] : blocks;
}
