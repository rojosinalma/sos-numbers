import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../borders.dart';
import '../detection.dart';
import '../native.dart';
import '../numbers_repository.dart';
import '../theme.dart';
import 'country_picker.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _askedLocationPrefKey = 'asked_location';

  NumbersRepository? _repo;
  CountryDetector? _detector;
  Detection? _detection;
  String? _loadError;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The border data is 2.6 MB of bytes; do not hold it while backgrounded.
    if (state == AppLifecycleState.paused) Borders.releaseMemory();
  }

  Future<void> _boot() async {
    final NumbersRepository repo;
    final CountryDetector detector;
    final Detection quick;
    try {
      repo = await NumbersRepository.load();
      detector = CountryDetector(repo);
      quick = await detector.detectQuick();
    } catch (e) {
      // Only the dataset itself failing is fatal. Everything after this point
      // is best-effort and must never take the numbers off the screen.
      if (!mounted) return;
      setState(() => _loadError = '$e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _repo = repo;
      _detector = detector;
      _detection = quick;
    });

    // A manual choice is final; do not spend a GPS fix on it.
    if (quick.isManual) return;

    final bool asked = await Native.prefGet(_askedLocationPrefKey) == '1';
    if (!quick.locationPermitted && !asked && !quick.locationPermanentlyDenied) {
      await Native.prefSet(_askedLocationPrefKey, '1');
      await _refineLocation(requestPermission: true);
    } else if (quick.locationPermitted) {
      await _refineLocation();
    }
  }

  Future<void> _refineLocation({bool requestPermission = false}) async {
    final CountryDetector? detector = _detector;
    final Detection? current = _detection;
    if (detector == null || current == null || _locating) return;

    setState(() => _locating = true);
    try {
      final Detection refined = await detector.refineWithLocation(
        current,
        requestPermission: requestPermission,
      );
      if (!mounted) return;
      setState(() => _detection = refined);
    } catch (_) {
      // refineWithLocation already guards its internals; this is the last line
      // of defence so a location problem can never become a red screen.
      if (mounted) _toast('Could not use your location. Showing the best guess.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// The banner's location button: request if we still can, otherwise take the
  /// user to app settings, which is the only place a permanent denial can be undone.
  Future<void> _onLocationAction(Detection detection) async {
    if (detection.locationPermitted) {
      await _refineLocation();
      return;
    }
    if (detection.locationPermanentlyDenied) {
      final bool opened = await Native.openAppSettings();
      if (!opened && mounted) {
        _toast('Open Android Settings > Apps > Emergency Numbers > Permissions');
      }
      return;
    }
    await _refineLocation(requestPermission: true);
  }

  Future<void> _redetect() async {
    final CountryDetector? detector = _detector;
    if (detector == null) return;
    final Detection quick = await detector.detectQuick();
    if (!mounted) return;
    setState(() => _detection = quick);
    if (!quick.isManual && quick.locationPermitted) await _refineLocation();
  }

  Future<void> _changeCountry() async {
    final NumbersRepository? repo = _repo;
    final CountryDetector? detector = _detector;
    final Detection? detection = _detection;
    if (repo == null || detector == null) return;

    final String? choice = await CountryPicker.show(
      context,
      repo: repo,
      currentIso: detection?.iso,
      isManual: detection?.isManual ?? false,
    );
    if (choice == null) return;

    final bool saved = await detector.setManual(choice == 'auto' ? null : choice);
    if (!saved && mounted) {
      _toast('Could not save your choice; it may reset next time.');
    }
    await _redetect();
  }

  Future<void> _dial(String number) async {
    bool ok = false;
    try {
      ok = await Native.openDialer(number);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      _toast('No dialer app available. Number: $number');
    }
  }

  Future<void> _copy(String number) async {
    await Clipboard.setData(ClipboardData(text: number));
    if (mounted) _toast('Copied $number');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency Numbers',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: <Widget>[
          if (_locating)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Dracula.cyan),
              ),
            )
          else
            IconButton(
              tooltip: 'Detect again',
              onPressed: _redetect,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final NumbersRepository? repo = _repo;
    final Detection? detection = _detection;

    // The fatal card is only ever shown when there is genuinely nothing to show.
    // Once numbers are on screen, no later failure may replace them.
    final String? error = _loadError;
    if (error != null && repo == null) {
      return _CenteredMessage(
        icon: Icons.error_outline,
        colour: Dracula.red,
        title: 'Could not load the emergency number data',
        detail: '$error\n\nIf you are in an emergency now, try 112 or 911.',
      );
    }

    if (repo == null || detection == null) {
      return const Center(
          child: CircularProgressIndicator(color: Dracula.purple));
    }

    final CountryNumbers? country = repo.forIso(detection.iso);
    // A country with no dialable number at all is treated exactly like no
    // country: the dataset guarantees this cannot happen today, but a `!` on
    // the emergency screen is not a bet worth making.
    final String? primary = country?.primary;

    return RefreshIndicator(
      onRefresh: _redetect,
      color: Dracula.purple,
      backgroundColor: Dracula.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _CountryHeader(
            detection: detection,
            country: country,
            onChange: _changeCountry,
          ),
          const SizedBox(height: 16),
          if (country == null || primary == null)
            _CenteredMessage(
              icon: Icons.help_outline,
              colour: Dracula.orange,
              title: country == null
                  ? 'Country not determined'
                  : 'No number on file for ${country.name}',
              detail: 'Pick your country to see its emergency numbers. '
                  'In most places 112 or 911 will connect you.',
              action: FilledButton.icon(
                onPressed: _changeCountry,
                icon: const Icon(Icons.public),
                label: const Text('Choose country'),
              ),
            )
          else ...<Widget>[
            _EmergencyButton(
              number: primary,
              universal: country.hasUniversalNumber,
              onTap: () => _dial(primary),
              onLongPress: () => _copy(primary),
            ),
            const SizedBox(height: 12),
            _ServiceGrid(
              country: country,
              onDial: _dial,
              onCopy: _copy,
            ),
            if (!detection.source.isTrustworthy) ...<Widget>[
              const SizedBox(height: 12),
              _Banner(
                icon: Icons.warning_amber_rounded,
                colour: Dracula.orange,
                title: 'Verify this country',
                body: detection.source.caveat,
                actionLabel: detection.locationPermitted
                    ? 'Use my location'
                    : detection.locationPermanentlyDenied
                        ? 'Open app settings'
                        : 'Allow location',
                onAction: () => _onLocationAction(detection),
              ),
            ],
            if (detection.signalsDisagree) ...<Widget>[
              const SizedBox(height: 12),
              _Banner(
                icon: Icons.alt_route,
                colour: Dracula.cyan,
                title: 'Near a border?',
                body: 'Your location says ${detection.gpsIso} but your mobile '
                    'network says ${detection.networkIso}. Showing '
                    '${detection.iso}. Change it if that is wrong.',
                actionLabel: 'Change',
                onAction: _changeCountry,
              ),
            ],
            if (country.notes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              _NotesCard(notes: country.notes),
            ],
            const SizedBox(height: 12),
            _DetailsCard(detection: detection, repo: repo),
          ],
          const SizedBox(height: 20),
          const _Disclaimer(),
        ],
      ),
    );
  }
}

class _CountryHeader extends StatelessWidget {
  const _CountryHeader({
    required this.detection,
    required this.country,
    required this.onChange,
  });

  final Detection detection;
  final CountryNumbers? country;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 56,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Dracula.currentLine,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                detection.iso ?? '??',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    country?.name ?? 'Unknown country',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      Icon(
                        switch (detection.source) {
                          CountrySource.manual => Icons.push_pin,
                          CountrySource.gps => Icons.my_location,
                          CountrySource.network => Icons.cell_tower,
                          CountrySource.sim => Icons.sim_card,
                          CountrySource.locale => Icons.language,
                          CountrySource.none => Icons.help_outline,
                        },
                        size: 14,
                        color: detection.source.isTrustworthy
                            ? Dracula.green
                            : Dracula.orange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          detection.source.label,
                          style: TextStyle(
                            fontSize: 13,
                            color: detection.source.isTrustworthy
                                ? Dracula.green
                                : Dracula.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onChange,
              style: TextButton.styleFrom(foregroundColor: Dracula.purple),
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmergencyButton extends StatelessWidget {
  const _EmergencyButton({
    required this.number,
    required this.universal,
    required this.onTap,
    required this.onLongPress,
  });

  final String number;
  final bool universal;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Dial emergency number $number',
      child: Material(
        color: Dracula.red,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
            child: Row(
              children: <Widget>[
                const Icon(Icons.phone_in_talk,
                    size: 40, color: Dracula.background),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        number,
                        style: const TextStyle(
                          fontSize: 44,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          color: Dracula.background,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        universal
                            ? 'ALL EMERGENCY SERVICES'
                            : 'MAIN EMERGENCY NUMBER',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Dracula.background,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 28, color: Dracula.background),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ServiceGrid extends StatelessWidget {
  const _ServiceGrid({
    required this.country,
    required this.onDial,
    required this.onCopy,
  });

  final CountryNumbers country;
  final void Function(String) onDial;
  final void Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final List<ServiceNumber> services = country.services;
    if (services.isEmpty) return const SizedBox.shrink();

    return Column(
      children: <Widget>[
        for (final ServiceNumber s in services)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ServiceTile(
              service: s,
              onTap: () => onDial(s.number),
              onLongPress: () => onCopy(s.number),
            ),
          ),
      ],
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.onTap,
    required this.onLongPress,
  });

  final ServiceNumber service;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color colour, String label) = switch (service.service) {
      Service.police => (Icons.local_police, Dracula.cyan, 'Police'),
      Service.ambulance => (Icons.medical_services, Dracula.green, 'Ambulance'),
      Service.fire => (Icons.local_fire_department, Dracula.orange, 'Fire'),
      Service.general => (Icons.emergency, Dracula.red, 'Emergency'),
    };

    return Material(
      color: Dracula.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Dracula.currentLine),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            children: <Widget>[
              Icon(icon, color: colour, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                service.number,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: colour,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.phone, size: 18, color: Dracula.comment),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.colour,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color colour;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withValues(alpha: 0.45)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: colour, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: colour)),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(
                        fontSize: 13, color: Dracula.foreground, height: 1.35)),
                if (actionLabel != null && onAction != null) ...<Widget>[
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: colour,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 18, color: Dracula.purple),
                SizedBox(width: 8),
                Text('Local notes',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: Dracula.purple)),
              ],
            ),
            const SizedBox(height: 8),
            Text(notes,
                style: const TextStyle(fontSize: 13.5, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.detection, required this.repo});

  final Detection detection;
  final NumbersRepository repo;

  @override
  Widget build(BuildContext context) {
    final GeoFix? fix = detection.fix;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          leading: const Icon(Icons.travel_explore,
              size: 20, color: Dracula.comment),
          title: const Text('How this was detected',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          iconColor: Dracula.comment,
          collapsedIconColor: Dracula.comment,
          children: <Widget>[
            _row('Mobile network', detection.networkIso ?? 'not available'),
            _row('SIM card', detection.simIso ?? 'not available'),
            _row('Phone language', detection.localeIso ?? 'not available'),
            _row(
              'Location',
              detection.gpsIso ??
                  (detection.gpsUnsupportedIso != null
                      ? '${detection.gpsUnsupportedIso} (no numbers on file)'
                      : detection.locationPermanentlyDenied
                          ? 'permission denied permanently'
                          : detection.locationPermitted
                              ? (detection.locationError ?? 'not used')
                              : 'permission not granted'),
            ),
            if (fix != null)
              _row(
                'Fix',
                '${fix.latitude.toStringAsFixed(4)}, '
                    '${fix.longitude.toStringAsFixed(4)} '
                    '(${fix.provider}'
                    '${fix.accuracyMetres != null ? ', ±${fix.accuracyMetres!.round()} m' : ''})',
              ),
            _row('Using', '${detection.iso ?? '—'} · ${detection.source.label}'),
            const SizedBox(height: 6),
            Text(detection.source.caveat,
                style: const TextStyle(fontSize: 12, color: Dracula.comment)),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 118,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, color: Dracula.comment)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final NumbersRepository? repo = NumbersRepository.instanceOrNull;
    return Column(
      children: <Widget>[
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.wifi_off, size: 14, color: Dracula.green),
            SizedBox(width: 6),
            Text('Works fully offline. No internet permission.',
                style: TextStyle(fontSize: 12, color: Dracula.green)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Numbers come from Wikipedia and may be out of date or incomplete. '
          'If a number does not connect, try 112 or 911 — most networks route '
          'them to local services.'
          '${repo != null ? '\n${repo.length} countries · data ${repo.generatedUtc.split('T').first}' : ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 11.5, color: Dracula.comment, height: 1.45),
        ),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.colour,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final Color colour;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Icon(icon, color: colour, size: 34),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Dracula.comment)),
            if (action != null) ...<Widget>[
              const SizedBox(height: 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
