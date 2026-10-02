import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'domain.dart';

class CareRepository extends ChangeNotifier {
  CareRepository.live(this.uid, this.role, this.centerId) : demo = false {
    _subscribe();
  }
  CareRepository.demo({this.role = 'staff'})
    : uid = 'demo-user',
      centerId = 'demo',
      demo = true {
    final d = centerTime(DateTime.now());
    for (var i = 0; i < 6; i++) {
      final id = 'DC-${(i + 1).toString().padLeft(3, '0')}';
      final name = [
        'Maria Santos',
        'Jose Reyes',
        'Ana Cruz',
        'Ramon Diaz',
        'Liza Garcia',
        'David Lim',
      ][i];
      patients.add(
        CareRecord(id, {
          'name': name,
          'gender': i.isEven ? 'Female' : 'Male',
          'birth': '1970-01-01',
          'contact': '+639170000000',
          'address': 'Demo address',
          'relativeName': 'Elena $name',
          'relativeRelationship': 'Sister',
          'relativePhone': '+639170000001',
          'relativeUid': 'demo-user',
          'emergencyName': 'Luis $name',
          'emergencyRelationship': 'Brother',
          'emergencyPhone': '+639170000002',
          'emergencyUid': 'demo-emergency',
          'version': 1,
        }),
      );
      final start = DateTime.utc(
        d.year,
        d.month,
        d.day,
        0 + i,
      ).millisecondsSinceEpoch;
      sessions.add(
        CareRecord('session-$i', {
          'patientId': id,
          'patientName': name,
          'startMs': start,
          'endMs': start + 3600000,
          'day': centerDay(
            DateTime.fromMillisecondsSinceEpoch(start, isUtc: true),
          ),
          'batch': ['Batch A', 'Batch B', 'Batch C'][i % 3],
          'room': 'Room ${i + 1}',
          'status': [
            'Scheduled',
            'Waiting',
            'In Progress',
            'Completed',
            'Ready for Pickup',
            'Missed',
          ][i],
          'version': 1,
          'pickupResponse': 'Awaiting response',
          if(i==4) 'pickupRecipientUid':'demo-user',
          if(i==4) 'pickupRequestedMs':DateTime.now().millisecondsSinceEpoch,
          if(i==4) 'pickupGeneration':1,
        }),
      );
    }
    templates.addAll(
      templateNames.map(
        (n) => CareRecord(n, {
          'push': '{name}: $n at {center}, {date}.',
          'sms': '{center}: $n. Please check the app or contact the center.',
        }),
      ),
    );
  }
  final bool demo;
  final String uid, role, centerId;
  bool get staff => role == 'staff' || role == 'admin';
  bool loading = false, busy = false, disposed = false;
  String? error;
  final patients = <CareRecord>[],
      sessions = <CareRecord>[],
      notifications = <CareRecord>[],
      audit = <CareRecord>[],
      templates = <CareRecord>[];
  final _subscriptions = <StreamSubscription>[];
  final _loadErrors = <String,String>{};
  int _serial = 0;
  final settings = <String,dynamic>{'name':'DialyCare','escalationMinutes':15};
  final preferences = <String,dynamic>{'preferredChannel':'push','pushEnabled':true};
  int get escalationMinutes => (settings['escalationMinutes'] as num?)?.toInt() ?? 15;
  static const templateNames = [
    'Schedule Confirmed',
    'Schedule Reminder',
    'Schedule Changed',
    'Session Started',
    'Session Ending Soon',
    'Session Completed',
    'Ready for Pickup',
    'Pickup Confirmed',
    'Center Announcements',
  ];
  void _changed() {
    if (!disposed) notifyListeners();
  }

  void _subscribe() {
    loading = true;
    final root = FirebaseFirestore.instance
        .collection('dcCenters')
        .doc(centerId);
    _subscriptions.add(root.snapshots().listen((s){settings.addAll(s.data()??{});_changed();},onError:(Object e){error='Center settings unavailable: $e';_changed();}));
    _subscriptions.add(FirebaseFirestore.instance.doc('dcUsers/$uid/private/preferences').snapshots().listen((s){preferences.addAll(s.data()??{});_changed();},onError:(Object e){error='Preferences unavailable: $e';_changed();}));
    final collections = <String, List<CareRecord>>{
      'sessions': sessions,
      'notifications': notifications,
      if (staff) 'patients': patients,
      if (staff) 'audit': audit,
      if (staff) 'templates': templates,
    };
    var pending = collections.length;
    for (final e in collections.entries) {
      Query<Map<String, dynamic>> query = root.collection(e.key);
      if (!staff) {
        query = e.key == 'sessions'
            ? query.where('viewerUids', arrayContains: uid)
            : query.where('recipientUid', isEqualTo: uid);
      }
      var received = false;
      _subscriptions.add(
        query.snapshots().listen(
          (snap) {
            e.value
              ..clear()
              ..addAll(snap.docs.map((d) => CareRecord(d.id, d.data())));
            if (!received) {
              received = true;
              pending--;
            }
            loading = pending > 0;
            _loadErrors.remove(e.key);
            error = _loadErrors.isEmpty ? null : _loadErrors.values.join('\n');
            _changed();
          },
          onError: (Object failure) {
            loading = false;
            _loadErrors[e.key]='Unable to load ${e.key}. Check access and backend setup. $failure';
            error = _loadErrors.values.join('\n');
            _changed();
          },
        ),
      );
    }
  }

  CareRecord? patient(String id) {
    for (final p in patients) {
      if (p.id == id) return p;
    }
    return null;
  }

  CareRecord? session(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> command(String action, Map<String, dynamic> data) async {
    if (busy) throw StateError('A change is already being saved.');
    busy = true;
    _changed();
    try {
      if (demo) {
        _demoCommand(action, data);
      } else {
        await _call(action, data);
      }
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _call(String action, Map<String, dynamic> data) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) throw StateError('Sign in again.');
    final project = Firebase.app().options.projectId;
    const region = String.fromEnvironment(
      'FUNCTIONS_REGION',
      defaultValue: 'asia-southeast1',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(
        Uri.parse('https://$region-$project.cloudfunctions.net/careCommand'),
      );
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'data': {
            'action': action,
            'centerId': centerId,
            'requestId':
                '$uid-${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
            ...data,
          },
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      if (body['error'] != null || response.statusCode != 200) {
        throw StateError(
          body['error']?['message']?.toString() ??
              'The server could not save this change.',
        );
      }
    } on TimeoutException {
      throw StateError(
        'The result is unknown. Refresh the record before retrying to avoid repeating an action.',
      );
    } finally {
      client.close();
    }
  }

  void _demoCommand(String action, Map<String, dynamic> d) {
    if (!staff &&
        ![
          'respondPickup',
          'markRead',
          'preferences',
          'registerToken',
        ].contains(action)) {
      throw StateError('Staff authorization required.');
    }
    final id =
        d['id']?.toString() ?? 'demo-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (action == 'savePatient') {
      final p = patient(id);
      if (p != null && d['version'] != p.number('version')) {
        throw StateError('Record changed. Reopen it.');
      }
      patients.removeWhere((p) => p.id == id);
      patients.add(
        CareRecord(id, {...d, 'version': (p?.number('version') ?? 0) + 1}),
      );
    } else if (action == 'archivePatient') {
      if (sessions.any(
        (s) =>
            s.text('patientId') == id &&
            !['Picked Up', 'Cancelled', 'Missed'].contains(s.text('status')),
      )) {
        throw StateError('Resolve active schedules before archiving.');
      }
      patients.removeWhere((p) => p.id == id);
    } else if (action == 'saveSchedule') {
      final old = session(id);
      if (old != null && d['version'] != old.number('version')) {
        throw StateError('Schedule changed. Reopen it.');
      }
      if (old != null && !['Scheduled', 'Waiting'].contains(old.text('status'))) {
        throw StateError(
          'Only scheduled or waiting sessions can be reassigned.',
        );
      }
      validateSchedule(d, sessions, id);
      final p = patient(d['patientId']);
      if (p == null) throw StateError('Choose a patient.');
      sessions.removeWhere((s) => s.id == id);
      sessions.add(
        CareRecord(id, {
          ...d,
          'patientName': p.text('name'),
          'day': centerDay(
            DateTime.fromMillisecondsSinceEpoch(d['startMs'], isUtc: true),
          ),
          'status': old?.text('status') ?? 'Scheduled',
          'version': (old?.number('version') ?? 0) + 1,
        }),
      );
      _demoNotice(id, old == null ? 'Schedule Confirmed' : 'Schedule Changed');
    } else if (action == 'transition') {
      final s = session(id);
      if (s == null) throw StateError('Session not found.');
      if (d['version'] != s.number('version')) {
        throw StateError('Session changed. Reopen it.');
      }
      final target = d['status'];
      if (!(sessionTransitions[s.text('status')] ?? []).contains(target)) {
        throw StateError('Invalid status transition.');
      }
      s.data['status'] = target;
      s.data['version'] = s.number('version') + 1;
      if (target == 'Ready for Pickup') {
        s.data['pickupRequestedMs'] = now;
        s.data['pickupResponse'] = 'Awaiting response';
        s.data['pickupRecipientUid'] = patient(s.text('patientId'))
            ?.text('relativeUid');
      }
      if ([
        'In Progress',
        'Completed',
        'Ready for Pickup',
        'Picked Up',
      ].contains(target)) {
        _demoNotice(
          id,
          {
                'In Progress': 'Session Started',
                'Completed': 'Session Completed',
                'Picked Up': 'Pickup Confirmed',
              }[target] ??
              target,
        );
      }
    } else if (action == 'escalate') {
      final s = session(id)!;
      if (s.text('status') != 'Ready for Pickup' || s.data['escalated'] == true) {
        throw StateError('No pending escalation.');
      }
      if (s.text('pickupResponse') != 'Cannot Pick Up' &&
          now - s.number('pickupRequestedMs') < escalationMinutes * 60000) {
        throw StateError('Wait for the response threshold or a refusal.');
      }
      s.data['escalated'] = true;
      s.data['pickupRecipientUid'] = patient(s.text('patientId'))
          ?.text('emergencyUid');
      s.data['pickupResponse'] = 'Awaiting emergency contact';
      _demoNotice(id, 'Ready for Pickup', emergency: true);
    } else if (action == 'respondPickup') {
      final s = session(id)!;
      if (s.text('status') != 'Ready for Pickup' ||
          s.text('pickupRecipientUid') != uid) {
        throw StateError('This pickup request is not assigned to you.');
      }
      if (!['I Can Pick Up', 'Cannot Pick Up'].contains(d['response'])) {
        throw StateError('Invalid response.');
      }
      s.data['pickupResponse'] = d['response'];
      s.data['responseMs'] = now;
    } else if (action == 'markRead') {
      for (final n in notifications.where(
        (n) => d['all'] == true || n.id == id,
      )) {
        n.data['readBy'] = [...List<String>.from(n.data['readBy'] ?? []), uid];
      }
    } else if (action == 'configureCenter') {
      if(role!='admin') throw StateError('Admin authorization required.');
      if((d['escalationMinutes'] as int)<1) throw StateError('Choose a positive response window.');
      settings.addAll(d);
    } else if(action=='preferences') {
      preferences.addAll(d);
    } else if(action=='verifyContact') {
      if(role!='admin') throw StateError('Admin authorization required.');
      final p=patient(id);if(p==null)throw StateError('Patient not found.');
      p.data['${d['contactKind']}PhoneVerified']=true;
      p.data['${d['contactKind']}SmsConsent']=d['consent']==true;
    } else if (action == 'saveTemplate') {
      if (role != 'admin') throw StateError('Admin authorization required.');
      templates.removeWhere((t) => t.id == id);
      templates.add(CareRecord(id, d));
    } else if (action == 'announcement') {
      _demoNotice('', 'Center Announcements', message: d['message']);
    } else if (![
      'preferences',
      'registerToken',
      'contactLog',
    ].contains(action)) {
      throw StateError('Unknown command.');
    }
    audit.add(
      CareRecord('audit-${audit.length}', {
        'action': action,
        'recordId': id,
        'actorUid': uid,
        'atMs': now,
        'reason': d['reason'] ?? '',
        'mode': 'demo',
      }),
    );
  }

  void _demoNotice(
    String id,
    String type, {
    bool emergency = false,
    String? message,
  }) {
    final key =
        '$id-$type-${session(id)?.number('version') ?? 0}-${emergency ? 'emergency' : 'relative'}';
    if (notifications.any((n) => n.id == key)) return;
    notifications.add(
      CareRecord(key, {
        'type': type,
        'sessionId': id,
        'patientId': session(id)?.text('patientId') ?? '',
        'recipientName': emergency ? 'Demo emergency contact' : 'Demo relative',
        'recipientUid': uid,
        'pushMessage': message ?? '$type. Please check DialyCare for details.',
        'smsMessage': 'DialyCare: an update is available. Contact the center.',
        'createdMs': DateTime.now().millisecondsSinceEpoch,
        'state': 'Demo only - not sent',
        'attempts': <dynamic>[],
        'readBy': <String>[],
      }),
    );
  }

  @override
  void dispose() {
    disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }
}
