import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:core_shared/core_shared.dart';

import 'firebase_options.dart';

@pragma('vm:entry-point')
Future<void> backgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? error;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(backgroundMessage);
  } catch (e) {
    error = 'Firebase setup unavailable: $e';
  }
  runApp(MyApp(initializationError: error));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.repository, this.initializationError});
  final CareRepository? repository;
  final String? initializationError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DialyCare',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF004A73)),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: repository != null
        ? MobileHome(repo: repository!)
        : AccessGate(
            mobile: true,
            initializationError: initializationError,
            builder: (r) => MobileHome(repo: r),
          ),
  );
}

class MobileHome extends StatefulWidget {
  const MobileHome({super.key, required this.repo});
  final CareRepository repo;
  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  CareRepository get repo => widget.repo;
  int tab = 0;
  String channel = 'push';
  bool push = true;
  bool preferencesDirty = false;
  String? pushStatus;
  final subs = <StreamSubscription>[];
  @override
  void initState() {
    super.initState();
    repo.addListener(changed);
    channel=repo.preferences['preferredChannel']?.toString()??'push';push=repo.preferences['pushEnabled']!=false;
    if (!repo.demo) {
      subs.add(
        FirebaseMessaging.onMessage.listen((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('New DialyCare update. Open Notifications.'),
              ),
            );
          }
        }),
      );
      subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => opened(m)));
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null) opened(m);
      });
    }
  }

  void opened(RemoteMessage m) {
    if (mounted) setState(() => tab = 1);
  }

  void changed() {
    if(!preferencesDirty){channel=repo.preferences['preferredChannel']?.toString()??'push';push=repo.preferences['pushEnabled']!=false;}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    repo.removeListener(changed);
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<bool> run(String action, Map<String, dynamic> d) async {
    try {
      await repo.command(action, d);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
      return false;
    }
  }

  Future<void> enablePush() async {
    if (repo.demo) {
      setState(() => pushStatus = 'Demo: push is not registered or sent.');
      return;
    }
    try {
      final result = await FirebaseMessaging.instance.requestPermission();
      if (result.authorizationStatus == AuthorizationStatus.denied) {
        setState(
          () => pushStatus =
              'Permission denied. You can still read updates in the app.',
        );
        return;
      }
      if (DefaultFirebaseOptions.currentPlatform.iosBundleId != null) {
        final apns = await FirebaseMessaging.instance.getAPNSToken();
        if (apns == null) {
          throw StateError(
            'APNs token not ready; retry after Apple push setup.',
          );
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) throw StateError('No push token available.');
      await repo.command('registerToken', {'token': token, 'enabled': true});
      subs.add(
        FirebaseMessaging.instance.onTokenRefresh.listen(
          (t) => run('registerToken', {'token': t, 'enabled': push}),
        ),
      );
      if (mounted) {
        setState(
          () => pushStatus = 'Push token registered. Delivery depends on provider/device availability.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => pushStatus = 'Push registration unavailable: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('DialyCare • ${repo.role}'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          onPressed: () async {
            if (repo.demo) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Use Exit demo to leave.')),
              );
            } else {
              await run('registerToken', {'token':'','enabled':false});
              await FirebaseAuth.instance.signOut();
            }
          },
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.calendar_month),
          label: 'My schedules',
        ),
        NavigationDestination(
          icon: Icon(Icons.notifications_outlined),
          label: 'Notifications',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Preferences',
        ),
      ],
    ),
    body: repo.loading
        ? const Center(child: CircularProgressIndicator())
        : repo.error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(repo.error!),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(18),
            children: [
              if (repo.demo)
                const Text(
                  'DEMO • local records; no delivery',
                  style: TextStyle(color: Colors.orange),
                ),
              if (tab == 0) ...[
                const Center(child: DialyCareLogo(size: 85)),
                const SizedBox(height: 18),
                Text(
                  repo.role == 'relative'
                      ? 'Linked patient schedules'
                      : 'Your schedules',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Text('Times shown in Asia/Manila.'),
                if (repo.sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Text(
                      'No authorized schedules yet. Ask your center to link your account.',
                    ),
                  ),
                for (final s in repo.sessions)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.text('patientName'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${centerDateTime(s.data['startMs'])}\n${s.text('batch')} • ${s.text('room')}',
                          ),
                          Chip(label: Text(s.text('status'))),
                          if (s.text('status') == 'Ready for Pickup') ...[
                            Text(
                              'Pickup response: ${s.text('pickupResponse', 'Awaiting response')}',
                            ),
                            if (repo.role == 'relative' &&
                                s.text('pickupRecipientUid') == repo.uid)
                              Wrap(
                                spacing: 8,
                                children: [
                                  for (final response in [
                                    'I Can Pick Up',
                                    'Cannot Pick Up',
                                  ])
                                    FilledButton(
                                      onPressed: repo.busy
                                          ? null
                                          : () => run('respondPickup', {
                                              'id': s.id,
                                              'pickupGeneration': s.number(
                                                'pickupGeneration',
                                              ),
                                              'response': response,
                                            }),
                                      child: Text(response),
                                    ),
                                ],
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
              if (tab == 1) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Notifications',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => run('markRead', {'all': true}),
                      child: const Text('Read all'),
                    ),
                  ],
                ),
                if (repo.notifications.isEmpty)
                  const Text('No notifications yet.'),
                for (final n in repo.notifications)
                  Card(
                    child: ListTile(
                      title: Text(n.text('type')),
                      subtitle: Text(
                        '${n.text('pushMessage')}\n${centerDateTime(n.data['createdMs'])}',
                      ),
                      onTap: () async {
                        await run('markRead', {'id': n.id});
                        if (!context.mounted) return;
                        showDialog<void>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(n.text('type')),
                            content: SingleChildScrollView(
                              child: Text(
                                '${n.text('pushMessage')}\n\nRecipient: ${n.text('recipientName')}\n${centerDateTime(n.data['createdMs'])}\n${n.text('state')}',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(c);
                                  setState(() => tab = 0);
                                },
                                child: const Text('My schedules'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
              if (tab == 2) ...[
                Text(
                  'Notification preferences',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: channel,
                  items: const [
                    DropdownMenuItem(
                      value: 'push',
                      child: Text('App notifications'),
                    ),
                    DropdownMenuItem(value: 'sms', child: Text('Prefer SMS')),
                  ],
                  onChanged: (v) => setState(() { preferencesDirty=true;channel = v!; }),
                ),
                SwitchListTile(
                  title: const Text('Enable app notifications'),
                  value: push,
                  onChanged: (v) => setState(() { preferencesDirty=true;push = v; }),
                ),
                const Text(
                  'SMS requires a verified registered phone and recorded consent. Ask your center to verify consent; choosing SMS alone does not grant it.',
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => run('preferences', {
                    'preferredChannel': channel,
                    'pushEnabled': push,
                  }),
                  child: const Text('Save preferences'),
                ),
                OutlinedButton(
                  onPressed: enablePush,
                  child: const Text('Register this device for push'),
                ),
                if (pushStatus != null) Text(pushStatus!),
              ],
            ],
          ),
  );
}

