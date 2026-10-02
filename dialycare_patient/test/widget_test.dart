import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:core_shared/core_shared.dart';
import 'package:dialycare_patient/main.dart';
void main(){
 for(final size in [const Size(360,800),const Size(390,844),const Size(768,1024)]){testWidgets('mobile views fit ${size.width}',(t)async{t.view.physicalSize=size;t.view.devicePixelRatio=1;addTearDown(t.view.resetPhysicalSize);addTearDown(t.view.resetDevicePixelRatio);final r=CareRepository.demo(role:'relative');addTearDown(r.dispose);await t.pumpWidget(MyApp(repository:r));await t.pumpAndSettle();expect(t.takeException(),isNull);for(final page in ['Notifications','Preferences','My schedules']){await t.tap(find.text(page).last);await t.pumpAndSettle();expect(t.takeException(),isNull,reason:page);}});}
 testWidgets('relative can acknowledge assigned pickup only',(t)async{final r=CareRepository.demo(role:'relative');addTearDown(r.dispose);r.sessions.removeWhere((s)=>s.id!='session-4');await t.pumpWidget(MyApp(repository:r));await t.pumpAndSettle();await t.ensureVisible(find.text('I Can Pick Up'));await t.tap(find.text('I Can Pick Up'));await t.pumpAndSettle();expect(r.sessions.single.text('pickupResponse'),'I Can Pick Up');expect(t.takeException(),isNull);});
 testWidgets('patient has no pickup response controls',(t)async{final r=CareRepository.demo(role:'patient');addTearDown(r.dispose);await t.pumpWidget(MyApp(repository:r));await t.pumpAndSettle();expect(find.text('I Can Pick Up'),findsNothing);});
}
