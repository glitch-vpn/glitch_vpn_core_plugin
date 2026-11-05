import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

const _linkOne = 'ss://chacha20-ietf-poly1305:pw@192.0.2.1:8388#one';
const _linkTwo = 'ss://chacha20-ietf-poly1305:pw@192.0.2.2:8388#two';

const _targets = VpnRouteTargets(
  servers: [
    VpnRouteServer(id: 's1', link: _linkOne),
    VpnRouteServer(id: 's2', link: _linkTwo),
  ],
  groups: [
    VpnRouteGroup(id: 'g1', servers: ['s1', 's2']),
  ],
  chains: [
    VpnRouteChain(id: 'c1', hops: ['s1', 's2']),
  ],
);

const _texts = VpnNotificationTexts(
  title: 'title',
  channel: 'channel',
  connecting: 'connecting',
  connected: 'connected',
  disconnecting: 'disconnecting',
  disconnectAction: 'disconnect',
  byteUnits: VpnByteUnits(
    bytes: 'b',
    kilobytes: 'kb',
    megabytes: 'mb',
    gigabytes: 'gb',
    terabytes: 'tb',
  ),
);

VpnRouting _routingWith({
  VpnRouteTargets? targets = _targets,
  List<VpnRoute> routes = const [
    VpnRoute(to: 'g1', match: ['domain:a.example']),
  ],
}) => VpnRouting(
  targets: targets,
  tiers: [VpnRoutingTier(routes: routes)],
);

void main() {
  tearDown(() {
    GlitchVpnCore.debugCapabilitiesJsonProvider = null;
    GlitchVpnCore.debugResetEngineIdsCache();
    VpnStatusChannel.instance.emit(VpnStatus.disconnected);
  });

  group('VpnRouting.toOpts with routes and targets', () {
    test('routes sit beside block, direct and proxy; targets go out whole', () {
      final opts = const VpnRouting(
        targets: _targets,
        tiers: [
          VpnRoutingTier(
            block: ['domain:blocked.example'],
            routes: [
              VpnRoute(to: 'g1', match: [' domain:a.example ', '']),
              VpnRoute(to: 'c1', match: ['domain:b.example']),
            ],
            proxy: ['domain:c.example'],
          ),
        ],
      ).toOpts();
      expect(opts.keys, {'routingTiers', 'routingTargets'});
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'block': ['domain:blocked.example'],
          'routes': [
            {
              'to': 'g1',
              'match': ['domain:a.example'],
            },
            {
              'to': 'c1',
              'match': ['domain:b.example'],
            },
          ],
          'proxy': ['domain:c.example'],
        },
      ]);
      expect(jsonDecode(opts['routingTargets']!), {
        'version': 1,
        'servers': [
          {'id': 's1', 'link': _linkOne},
          {'id': 's2', 'link': _linkTwo},
        ],
        'groups': [
          {
            'id': 'g1',
            'servers': ['s1', 's2'],
          },
        ],
        'chains': [
          {
            'id': 'c1',
            'hops': ['s1', 's2'],
          },
        ],
      });
    });

    test('a tier holding only routes is not dropped', () {
      final opts = _routingWith().toOpts();
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'routes': [
            {
              'to': 'g1',
              'match': ['domain:a.example'],
            },
          ],
        },
      ]);
    });

    test('without routes or targets no new key is emitted', () {
      final opts = const VpnRouting(
        tiers: [
          VpnRoutingTier(proxy: ['domain:vk.ru']),
        ],
        targets: VpnRouteTargets(),
      ).toOpts();
      expect(opts.keys, {'routingTiers'});
    });

    test('targets with no route still go out', () {
      final opts = const VpnRouting(targets: _targets).toOpts();
      expect(opts.keys, {'routingTargets'});
    });
  });

  group('validation mirrors the core', () {
    String? errorOf(VpnRouteTargets targets) => targets.validationError();

    test('a valid set passes', () {
      expect(_routingWith().validationError(), isNull);
    });

    test('ids: pattern, uniqueness across kinds', () {
      for (final id in ['', 'S1', 'a-b', 'a_b', 'x' * 17, 'é']) {
        expect(
          errorOf(
            VpnRouteTargets(
              servers: [VpnRouteServer(id: id, link: _linkOne)],
            ),
          ),
          contains('1-16'),
          reason: 'id "$id"',
        );
      }
      expect(
        errorOf(
          VpnRouteTargets(
            servers: [VpnRouteServer(id: 'x' * 16, link: _linkOne)],
          ),
        ),
        isNull,
      );
      expect(
        errorOf(
          const VpnRouteTargets(
            servers: [VpnRouteServer(id: 's1', link: _linkOne)],
            groups: [
              VpnRouteGroup(id: 's1', servers: ['s1']),
            ],
          ),
        ),
        contains('duplicate'),
      );
    });

    test('a server needs a link', () {
      expect(
        errorOf(
          const VpnRouteTargets(
            servers: [VpnRouteServer(id: 's1', link: ' ')],
          ),
        ),
        contains('no link'),
      );
    });

    test('groups: not empty, members are servers', () {
      const server = VpnRouteServer(id: 's1', link: _linkOne);
      expect(
        errorOf(
          const VpnRouteTargets(
            servers: [server],
            groups: [VpnRouteGroup(id: 'g1', servers: [])],
          ),
        ),
        contains('empty'),
      );
      expect(
        errorOf(
          const VpnRouteTargets(
            servers: [server],
            groups: [
              VpnRouteGroup(id: 'g1', servers: ['nope']),
            ],
          ),
        ),
        contains('unknown server'),
      );
    });

    test('chains: 2 to 4 hops, servers only, none twice', () {
      VpnRouteTargets chain(List<String> hops) => VpnRouteTargets(
        servers: [
          for (final id in ['s1', 's2', 's3', 's4', 's5'])
            VpnRouteServer(id: id, link: _linkOne),
        ],
        chains: [VpnRouteChain(id: 'c1', hops: hops)],
      );
      expect(errorOf(chain(['s1'])), contains('hops'));
      expect(errorOf(chain(['s1', 's2', 's3', 's4', 's5'])), contains('hops'));
      expect(errorOf(chain(['s1', 's2'])), isNull);
      expect(errorOf(chain(['s1', 's2', 's3', 's4'])), isNull);
      expect(errorOf(chain(['s1', 's1'])), contains('twice'));
      expect(errorOf(chain(['s1', 'nope'])), contains('unknown server'));
    });

    test('a group is no hop of a chain', () {
      expect(
        errorOf(
          const VpnRouteTargets(
            servers: [VpnRouteServer(id: 's1', link: _linkOne)],
            groups: [
              VpnRouteGroup(id: 'g1', servers: ['s1']),
            ],
            chains: [
              VpnRouteChain(id: 'c1', hops: ['s1', 'g1']),
            ],
          ),
        ),
        contains('unknown server'),
      );
    });

    test('counts are capped', () {
      expect(
        errorOf(
          VpnRouteTargets(
            servers: [
              for (var i = 0; i < 65; i++)
                VpnRouteServer(id: 's$i', link: _linkOne),
            ],
          ),
        ),
        contains('64 servers'),
      );
    });

    test('a route must name a defined id', () {
      expect(
        _routingWith(
          routes: const [
            VpnRoute(to: 'nope', match: ['domain:a.example']),
          ],
        ).validationError(),
        contains('undefined id "nope"'),
      );
      expect(
        _routingWith(targets: null).validationError(),
        contains('undefined id'),
      );
    });

    test('a route cannot match a process, whatever the case', () {
      for (final m in ['process:app.exe', ' PROCESS:app.exe']) {
        expect(
          _routingWith(
            routes: [
              VpnRoute(to: 's1', match: ['domain:a.example', m]),
            ],
          ).validationError(),
          contains('process'),
        );
      }
    });

    test('a bare process: prefix is not a process matcher', () {
      expect(
        _routingWith(
          routes: const [
            VpnRoute(to: 's1', match: ['process:']),
          ],
        ).validationError(),
        isNull,
      );
    });

    test('a route that matches nothing is refused', () {
      expect(
        _routingWith(
          routes: const [
            VpnRoute(to: 's1', match: [' ', '']),
          ],
        ).validationError(),
        contains('matches nothing'),
      );
    });

    test('toOpts throws ArgumentError on an invalid set', () {
      expect(
        () => _routingWith(targets: null).toOpts(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an error never carries a link', () {
      final error = const VpnRouteTargets(
        servers: [VpnRouteServer(id: 'BAD', link: _linkOne)],
      ).validationError();
      expect(error, isNot(contains('chacha')));
    });
  });

  group('routeTargetsSupported', () {
    Future<bool> supportedFor(String capabilities) {
      GlitchVpnCore.debugResetEngineIdsCache();
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async => capabilities;
      return GlitchVpnCore.routeTargetsSupported();
    }

    test('reads features', () async {
      expect(
        await supportedFor(
          '{"engines":["xray"],"features":["serverEvent","routeTargets"]}',
        ),
        isTrue,
      );
      expect(
        await supportedFor('{"engines":["xray"],"features":["serverEvent"]}'),
        isFalse,
      );
    });

    test('an older core, garbage and a failed read are unsupported', () async {
      expect(await supportedFor('{"engines":["xray"]}'), isFalse);
      expect(await supportedFor('{"features":"routeTargets"}'), isFalse);
      expect(await supportedFor('not json'), isFalse);
      GlitchVpnCore.debugResetEngineIdsCache();
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async =>
          throw StateError('no library');
      expect(await GlitchVpnCore.routeTargetsSupported(), isFalse);
    });
  });

  group('connect refuses a bad routing', () {
    Future<PlatformException> refusalOf(VpnRouting routing) async {
      GlitchVpnCore.debugResetEngineIdsCache();
      try {
        await GlitchVpnCore.instance.connect(
          engine: VpnEngine.xray,
          config: 'x',
          notification: _texts,
          routing: routing,
        );
      } on PlatformException catch (e) {
        return e;
      }
      fail('connect() returned without refusing');
    }

    test('INVALID_ROUTING names the problem', () async {
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async =>
          '{"engines":["xray"],"features":["routeTargets"]}';
      final e = await refusalOf(_routingWith(targets: null));
      expect(e.code, 'INVALID_ROUTING');
      expect(e.message, contains('undefined id'));
    });

    test('ROUTE_TARGETS_NOT_IN_BUILD on a core without the feature', () async {
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async =>
          '{"engines":["xray"]}';
      final e = await refusalOf(_routingWith());
      expect(e.code, 'ROUTE_TARGETS_NOT_IN_BUILD');
    });
  });
}
