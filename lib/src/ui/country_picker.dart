import 'package:flutter/material.dart';

import '../numbers_repository.dart';
import '../theme.dart';

/// Full-screen searchable country list. Returns the chosen ISO code, or the
/// string 'auto' to go back to automatic detection, or null when dismissed.
class CountryPicker extends StatefulWidget {
  const CountryPicker({
    super.key,
    required this.repo,
    this.currentIso,
    this.isManual = false,
  });

  final NumbersRepository repo;
  final String? currentIso;
  final bool isManual;

  static Future<String?> show(
    BuildContext context, {
    required NumbersRepository repo,
    String? currentIso,
    bool isManual = false,
  }) =>
      Navigator.of(context).push<String>(MaterialPageRoute<String>(
        builder: (_) => CountryPicker(
          repo: repo,
          currentIso: currentIso,
          isManual: isManual,
        ),
      ));

  @override
  State<CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<CountryPicker> {
  final TextEditingController _controller = TextEditingController();
  late List<CountryNumbers> _results = widget.repo.all;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) =>
      setState(() => _results = widget.repo.search(q));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose country')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              decoration: const InputDecoration(
                hintText: 'Search country or code',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (widget.isManual)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop('auto'),
                  icon: const Icon(Icons.my_location),
                  label: const Text('Back to automatic detection'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Dracula.cyan,
                    side: const BorderSide(color: Dracula.currentLine),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          Expanded(
            child: _results.isEmpty
                ? const Center(
                    child: Text('No match',
                        style: TextStyle(color: Dracula.comment)),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(
                        height: 1, color: Dracula.currentLine),
                    itemBuilder: (BuildContext context, int i) {
                      final CountryNumbers c = _results[i];
                      final bool selected = c.iso == widget.currentIso;
                      return ListTile(
                        leading: _IsoBadge(iso: c.iso, highlight: selected),
                        title: Text(c.name),
                        subtitle: Text(
                          c.services.isEmpty
                              ? (c.primary ?? '')
                              : c.services
                                  .map((ServiceNumber s) => s.number)
                                  .toSet()
                                  .join(' / '),
                          style: const TextStyle(color: Dracula.comment),
                        ),
                        trailing: selected
                            ? const Icon(Icons.check, color: Dracula.green)
                            : null,
                        onTap: () => Navigator.of(context).pop(c.iso),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _IsoBadge extends StatelessWidget {
  const _IsoBadge({required this.iso, this.highlight = false});

  final String iso;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlight ? Dracula.purple : Dracula.currentLine,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        iso,
        style: TextStyle(
          color: highlight ? Dracula.background : Dracula.foreground,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
