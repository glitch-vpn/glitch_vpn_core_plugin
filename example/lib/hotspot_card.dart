import 'dart:async';

import 'package:flutter/material.dart';
import 'package:glitch_vpn_core/vpn_hotspot_channel.dart';

/// Exercises [VpnHotspotChannel]: capability, configure, start, stop, the
/// device list and the block calls, which reach the core's sharing. The card
/// shows what was sent to the core and what the core reported.
class HotspotCard extends StatefulWidget {
  const HotspotCard({super.key});

  @override
  State<HotspotCard> createState() => _HotspotCardState();
}

class _HotspotCardState extends State<HotspotCard> {
  final _channel = VpnHotspotChannel.instance;
  final _ssidCtrl = TextEditingController(text: 'glitch-test');
  final _passphraseCtrl = TextEditingController();
  HotspotBand _band = HotspotBand.auto;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    unawaited(_channel.refreshCapability());
    unawaited(_channel.reconcile());
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await _channel.configure(
        ssid: _ssidCtrl.text,
        passphrase: _passphraseCtrl.text,
        band: _band,
      );
      setState(() => _inputError = null);
      if (_channel.value.state != HotspotState.on) await _channel.start();
    } on ArgumentError catch (e) {
      setState(() => _inputError = '${e.name}: ${e.message}');
    }
  }

  String _describe(HotspotUpdate update) => switch (update.state) {
    HotspotState.failed =>
      'failed: ${update.failure?.reason.name} ${update.failure?.detail}',
    final s => s.name,
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ValueListenableBuilder<HotspotUpdate>(
          valueListenable: _channel.listenable,
          builder: (context, update, _) {
            final busy = update.state == HotspotState.starting;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Wi-Fi hotspot (Windows)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Flexible(child: Text(_describe(update))),
                  ],
                ),
                ValueListenableBuilder<HotspotCapability?>(
                  valueListenable: _channel.capability,
                  builder: (context, capability, _) => Text(
                    capability == null
                        ? 'capability: unknown'
                        : capability.supported
                        ? 'supported, bands: '
                              '${capability.bands.map((b) => b.wire).join(', ')}'
                        : 'cannot host: ${capability.unsupportedReason?.name}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                TextField(
                  controller: _ssidCtrl,
                  decoration: const InputDecoration(labelText: 'Name (SSID)'),
                ),
                TextField(
                  controller: _passphraseCtrl,
                  decoration: InputDecoration(
                    labelText: 'Password (8 to 63 characters)',
                    errorText: _inputError,
                  ),
                ),
                DropdownButton<HotspotBand>(
                  value: _band,
                  items: [
                    for (final band
                        in _channel.capability.value?.bands ??
                            HotspotBand.values)
                      DropdownMenuItem(value: band, child: Text(band.wire)),
                  ],
                  onChanged: (band) =>
                      setState(() => _band = band ?? HotspotBand.auto),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy ? null : _start,
                      child: const Text('Start / apply'),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : _channel.stop,
                      child: const Text('Stop'),
                    ),
                    OutlinedButton(
                      onPressed: _channel.refreshClients,
                      child: const Text('Read devices'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Block while the tunnel is down'),
                  value: _channel.blockWhileTunnelDown,
                  onChanged: (v) =>
                      setState(() => _channel.setBlockWhileTunnelDown(v)),
                ),
                ValueListenableBuilder<List<HotspotClient>>(
                  valueListenable: _channel.clients,
                  builder: (context, clients, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in clients)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${c.name ?? '-'}  ${c.mac}  ${c.ipv4 ?? '-'}'
                                '${c.blocked ? '  blocked' : ''}',
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(
                                () => c.blocked
                                    ? _channel.unblockClient(c.mac)
                                    : _channel.blockClient(c.mac),
                              ),
                              child: Text(c.blocked ? 'Unblock' : 'Block'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                ValueListenableBuilder<HotspotSharingEvent?>(
                  valueListenable: _channel.sharing,
                  builder: (context, event, _) => Text(
                    'sent to the core: '
                    '${_channel.wantedSharing?.toJson() ?? '-'}\n'
                    'core reports: ${event == null ? '-' : 'shared ${event.shared}, '
                              'blocked ${event.blocked}, error "${event.error}"'}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
