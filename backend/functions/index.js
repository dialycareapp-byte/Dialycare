'use strict';
const {initializeApp}=require('firebase-admin/app');
const {getFirestore,FieldValue}=require('firebase-admin/firestore');
const {getMessaging}=require('firebase-admin/messaging');
const {onCall,HttpsError}=require('firebase-functions/v2/https');
const {onDocumentCreated}=require('firebase-functions/v2/firestore');
const {onSchedule}=require('firebase-functions/v2/scheduler');
const {defineSecret}=require('firebase-functions/params');
const crypto=require('node:crypto');
const D=require('./domain.cjs');
initializeApp(); const db=getFirestore(); const region='asia-southeast1';
const smsKey=defineSecret('DIALYCARE_SMS_API_KEY');
const safeId=x=>typeof x==='string'&&/^[A-Za-z0-9_-]{1,128}$/.test(x);
const contacts=p=>[
 {uid:p.patientUid||'',name:p.name,phone:p.contact||'',phoneVerified:p.patientPhoneVerified===true,smsConsent:p.patientSmsConsent===true,kind:'patient'},
 {uid:p.relativeUid||'',name:p.relativeName||'',phone:p.relativePhone||'',phoneVerified:p.relativePhoneVerified===true,smsConsent:p.relativeSmsConsent===true,kind:'relative'},
 {uid:p.emergencyUid||'',name:p.emergencyName||'',phone:p.emergencyPhone||'',phoneVerified:p.emergencyPhoneVerified===true,smsConsent:p.emergencySmsConsent===true,kind:'emergency'}];
const viewers=p=>[...new Set(contacts(p).map(c=>c.uid).filter(Boolean))];
function notify(tx,root,s,p,type,now,templates,settings,{emergency=false,eventSuffix=''}={}) {
 const recipients=type==='Ready for Pickup'?[contacts(p)[emergency?2:1]]:contacts(p).slice(0,2);
 for(const c of recipients){
   const key=crypto.createHash('sha256').update(`${s.id}:${s.version}:${type}:${c.kind}:${eventSuffix}`).digest('hex');
   const template=templates[type]||D.defaults[type];
   const vars={name:p.name||'Patient',date:new Date(s.startMs+8*3600000).toISOString().slice(0,16).replace('T',' ')+' PHT',center:settings.name||'DialyCare'};
   tx.create(root.collection('notifications').doc(key),{type,sessionId:s.id,patientId:s.patientId,recipientUid:c.uid,recipientName:c.name,contact:c,contactKind:c.kind,createdMs:now,pushMessage:D.render(template.push,vars),smsMessage:D.render(template.sms,vars),state:'queued',attempts:[],readBy:[],eventVersion:s.version,pickupGeneration:s.pickupGeneration||0});
 }
}
exports.careCommand=onCall({region},async request=>{
 if(!request.auth)throw new HttpsError('unauthenticated','Sign in first.');
 const d=request.data||{},uid=request.auth.uid;
 if(!safeId(d.centerId)||!safeId(d.requestId))throw new HttpsError('invalid-argument','Invalid request identifier.');
 const root=db.collection('dcCenters').doc(d.centerId),op=root.collection('operations').doc(d.requestId);
 const digest=crypto.createHash('sha256').update(JSON.stringify(d)).digest('hex');
 try{return await db.runTransaction(async tx=>{
   const [profileSnap,prior,settingsSnap,patientSnap,sessionSnap,templateSnap]=await Promise.all([
     tx.get(db.collection('dcUsers').doc(uid)),tx.get(op),tx.get(root),tx.get(root.collection('patients')),tx.get(root.collection('sessions')),tx.get(root.collection('templates'))]);
   const profile=profileSnap.data();
   D.requireRole(profile,['admin','staff','patient','relative']);
   if(profile.centerId!==d.centerId)throw Error('Wrong center.');
   if(prior.exists){if(prior.data().digest!==digest)throw Error('Request identifier reused with different content.');return {ok:true};}
   const staff=['staff','admin'].includes(profile.role),settings=settingsSnap.data()||{};
   if(!staff&&!['respondPickup','markRead','preferences','registerToken'].includes(d.action))throw Error('Staff authorization required.');
   const now=Date.now(),patients=patientSnap.docs.map(x=>({id:x.id,...x.data()})),sessions=sessionSnap.docs.map(x=>({id:x.id,...x.data()}));
   const templates=Object.fromEntries(templateSnap.docs.map(x=>[x.id,x.data()]));
   const id=d.id||crypto.randomUUID(),s=sessions.find(s=>s.id===id),p=patients.find(p=>p.id===id);
   if(!safeId(id)&&!['saveTemplate','markRead'].includes(d.action))throw Error('Invalid record ID.');
   let before=null,after=null;
   // Read any command-specific documents before writes.
   let readNotices=[];
   if(d.action==='markRead'){
     const q=staff?root.collection('notifications'):root.collection('notifications').where('recipientUid','==',uid);
     readNotices=(await tx.get(q)).docs.filter(n=>d.all===true||n.id===d.id);
   }
   const linkedProfiles={};
   if(d.action==='savePatient'){
     for(const [field,expected] of [['patientUid','patient'],['relativeUid','relative'],['emergencyUid','relative']]){
       const link=d[field]||'';if(!link)continue;
       if(!safeId(link))throw Error('Invalid linked account ID.');
       const linked=(await tx.get(db.collection('dcUsers').doc(link))).data();
       if(!linked||!linked.active||linked.centerId!==d.centerId||linked.role!==expected)throw Error('Linked account must be an active, authorized '+expected+' in this center.');
       linkedProfiles[field]=linked;
     }
   }
   if(d.action==='savePatient'){
     if(!d.name?.trim()||!d.birth||!d.contact?.trim()||!d.address?.trim())throw Error('Complete required personal information.');
     if(p&&p.version!==d.version)throw Error('Patient changed. Reopen before saving.');
     const fields=['name','birth','suffix','gender','contact','address','patientUid','relativeName','relativeRelationship','relativePhone','relativeUid','relativeAddress','emergencyName','emergencyRelationship','emergencyPhone','emergencyUid','emergencyAddress','blood','notes','allergies'];
     after={...(p||{}),...Object.fromEntries(fields.map(k=>[k,String(d[k]||'').trim()])),version:(p?.version||0)+1,archived:false};delete after.id;
     // Changing a phone revokes previous verification and consent; staff cannot assert either.
     for(const [phone,prefix] of [['contact','patient'],['relativePhone','relative'],['emergencyPhone','emergency']])if(after[phone]!==p?.[phone]){after[prefix+'PhoneVerified']=false;after[prefix+'SmsConsent']=false;}
     tx.set(root.collection('patients').doc(id),after);before=p||null;
     for(const v of sessions.filter(s=>s.patientId===id)) tx.update(root.collection('sessions').doc(v.id),{patientName:after.name,viewerUids:viewers(after),version:v.version+1});
   }else if(d.action==='verifyContact'){
     D.requireRole(profile,['admin']);if(!p||!['patient','relative','emergency'].includes(d.contactKind)||!d.reason?.trim())throw Error('Patient, contact and verification evidence required.');
     const phone=contacts(p).find(c=>c.kind===d.contactKind).phone;if(!/^\+[1-9]\d{7,14}$/.test(phone))throw Error('Use a registered E.164 phone number.');
     before=p;after={[d.contactKind+'PhoneVerified']:true,[d.contactKind+'SmsConsent']:d.consent===true,[d.contactKind+'ConsentEvidence']:d.reason};tx.update(root.collection('patients').doc(id),after);
   }else if(d.action==='archivePatient'){
     if(!p)throw Error('Patient not found.');
     if(sessions.some(s=>s.patientId===id&&!['Picked Up','Missed','Cancelled'].includes(s.status)))throw Error('Resolve active schedules first.');
     before=p;after={...p,archived:true};tx.update(root.collection('patients').doc(id),{archived:true,version:p.version+1});
   }else if(d.action==='saveSchedule'){
     const patient=patients.find(p=>p.id===d.patientId&&!p.archived);if(!patient)throw Error('Patient not found.');
     if(s&&s.version!==d.version)throw Error('Schedule changed. Reopen before saving.');
     if(s&&!['Scheduled','Waiting'].includes(s.status))throw Error('Only scheduled or waiting appointments can be edited.');
     if(s&&!d.reason?.trim())throw Error('Give a reason for the schedule change.');
     D.validateSchedule(d,sessions,id);
     after={id,patientId:patient.id,patientName:patient.name,startMs:d.startMs,endMs:d.endMs,day:D.day(d.startMs),batch:d.batch,room:d.room.trim(),status:s?.status||'Scheduled',viewerUids:viewers(patient),version:(s?.version||0)+1};before=s||null;
     tx.set(root.collection('sessions').doc(id),after);notify(tx,root,after,patient,s?'Schedule Changed':'Schedule Confirmed',now,templates,settings);
   }else if(d.action==='transition'){
     if(!s||s.version!==d.version)throw Error('Session changed. Reopen details.');D.assertTransition(s.status,d.status);
     if(['Cancelled','Missed','Picked Up'].includes(d.status)&&!d.reason?.trim())throw Error('Record the reason or confirmed handover.');
     before=s;after={...s,status:d.status,version:s.version+1,updatedMs:now};
     const patient=patients.find(p=>p.id===s.patientId);
     if(d.status==='Ready for Pickup'){
       if(!patient.relativeName)throw Error('Assign a designated relative first.');
       Object.assign(after,{pickupRequestedMs:now,pickupResponse:'Awaiting response',pickupRecipientUid:patient.relativeUid||'',pickupGeneration:(s.pickupGeneration||0)+1,escalated:false,escalationDueMs:now+(settings.escalationMinutes||15)*60000});
     }
     tx.set(root.collection('sessions').doc(id),after);
     const type={'In Progress':'Session Started',Completed:'Session Completed','Ready for Pickup':'Ready for Pickup','Picked Up':'Pickup Confirmed',Cancelled:'Schedule Changed'}[d.status];
     if(type)notify(tx,root,after,patient,type,now,templates,settings);
   }else if(d.action==='respondPickup'){
     const linkedPatient=patients.find(p=>p.id===s?.patientId);
     if(profile.role!=='relative'||!s||linkedPatient?.[s.escalated?'emergencyUid':'relativeUid']!==uid||s.status!=='Ready for Pickup'||s.pickupRecipientUid!==uid||s.pickupGeneration!==d.pickupGeneration)throw Error('This pickup request is not assigned to you or is no longer current.');
     if(!['I Can Pick Up','Cannot Pick Up'].includes(d.response))throw Error('Invalid response.');
     if(s.pickupResponse===d.response){tx.create(op,{digest,atMs:now});return {ok:true};}
     before=s;after={...s,pickupResponse:d.response,responseMs:now,responseUid:uid,version:s.version+1};tx.set(root.collection('sessions').doc(id),after);
   }else if(d.action==='escalate'){
     if(!s||!D.canEscalate(s,now,settings.escalationMinutes||15))throw Error('Escalation requires a refusal or an expired response window.');
     const patient=patients.find(p=>p.id===s.patientId);if(!patient.emergencyName)throw Error('Add an authorized emergency contact first.');
     before=s;after={...s,escalated:true,pickupRecipientUid:patient.emergencyUid||'',pickupResponse:'Awaiting emergency contact',pickupGeneration:(s.pickupGeneration||0)+1,version:s.version+1};tx.set(root.collection('sessions').doc(id),after);notify(tx,root,after,patient,'Ready for Pickup',now,templates,settings,{emergency:true});
   }else if(d.action==='markRead'){
     if(readNotices.length>400)throw Error('Read selection is too large; mark individual notifications.');
     for(const n of readNotices)tx.update(n.ref,{readBy:FieldValue.arrayUnion(uid)});
   }else if(d.action==='registerToken'){
     if(typeof d.token!=='string'||d.token.length>4096)throw Error('Invalid push token.');
     tx.set(db.collection('dcUsers').doc(uid).collection('private').doc('preferences'),{token:d.token,pushEnabled:d.enabled!==false,tokenUpdatedMs:now},{merge:true});
   }else if(d.action==='preferences'){
     if(!['push','sms'].includes(d.preferredChannel))throw Error('Invalid channel.');
     tx.set(db.collection('dcUsers').doc(uid).collection('private').doc('preferences'),{preferredChannel:d.preferredChannel,pushEnabled:d.pushEnabled===true},{merge:true});
   }else if(d.action==='saveTemplate'){
     D.requireRole(profile,['admin']);if(!D.templateNames.includes(d.id)||!d.push?.trim()||d.push.length>1500||!d.sms?.trim()||d.sms.length>500)throw Error('Invalid template.');
     tx.set(root.collection('templates').doc(d.id),{push:d.push,sms:d.sms,updatedMs:now,actorUid:uid});
   }else if(d.action==='configureCenter'){
     D.requireRole(profile,['admin']);if(!Number.isInteger(d.escalationMinutes)||d.escalationMinutes<1||d.escalationMinutes>1440)throw Error('Choose 1–1440 minutes.');
     tx.set(root,{name:String(d.name||'DialyCare'),escalationMinutes:d.escalationMinutes,smsAlways:d.smsAlways===true},{merge:true});
   }else if(d.action==='announcement'){
     D.requireRole(profile,['admin']);if(!d.message?.trim()||d.message.length>500)throw Error('Enter an announcement of up to 500 characters.');
     // One recipient per account, even when the same relative is linked to multiple patients.
     const seen=new Set();for(const patient of patients.filter(p=>!p.archived))for(const c of contacts(patient).slice(0,2)){
       const identity=c.uid||c.phone;if(!identity||seen.has(identity))continue;seen.add(identity);
       const nid=crypto.createHash('sha256').update(d.requestId+identity).digest('hex');
       tx.create(root.collection('notifications').doc(nid),{type:'Center Announcements',sessionId:'',patientId:'',recipientUid:c.uid,recipientName:c.name,contact:c,createdMs:now,pushMessage:d.message,smsMessage:d.message,state:'queued',attempts:[],readBy:[]});
     }
   }else if(d.action==='contactLog'){
     if(!s||!['relative','emergency'].includes(d.contactKind))throw Error('Choose a contact and session.');
     after={sessionId:id,contactKind:d.contactKind,channel:'manual phone',outcome:String(d.outcome||'Dialer opened; connection unconfirmed')};
   }else{throw Error('Unknown action.');}
   tx.create(root.collection('audit').doc(),{action:d.action,recordId:id,actorUid:uid,actorRole:profile.role,atMs:now,reason:String(d.reason||''),before,after});
   tx.create(op,{digest,atMs:now});return {ok:true};
 });}catch(e){if(e instanceof HttpsError)throw e;throw new HttpsError('failed-precondition',e.message);}
});

// Outbox claims are committed before network calls. Uncertain sends are never blindly retried.
exports.deliverNotification=onDocumentCreated({document:'dcCenters/{centerId}/notifications/{id}',region,secrets:[smsKey]},async event=>{
 const ref=event.data.ref,root=ref.parent.parent;
 const claimed=await db.runTransaction(async tx=>{const snap=await tx.get(ref);if(snap.data().state!=='queued')return null;tx.update(ref,{state:'sending',claimedMs:Date.now()});return snap.data();});
 if(!claimed)return;
 const [settingsSnap,prefsSnap]=await Promise.all([root.get(),claimed.recipientUid?db.doc(`dcUsers/${claimed.recipientUid}/private/preferences`).get():Promise.resolve(null)]);
 const settings=settingsSnap.data()||{},prefs=prefsSnap?.data()||{},attempts=[];
 if(claimed.patientId){
   const currentPatient=(await root.collection('patients').doc(claimed.patientId).get()).data();
   const current=currentPatient&&contacts(currentPatient).find(c=>c.kind===claimed.contact.kind);
   if(!current||current.uid!==claimed.contact.uid||current.phone!==claimed.contact.phone){await ref.update({state:'superseded: contact changed'});return;}
   claimed.contact=current;
 }
 if(claimed.recipientUid){const account=(await db.doc(`dcUsers/${claimed.recipientUid}`).get()).data();if(!account?.active||account.centerId!==root.id){await ref.update({state:'blocked: recipient access revoked'});return;}}
 const policy=D.channels(claimed.contact,prefs,settings);
 if(claimed.sessionId){
   const session=(await root.collection('sessions').doc(claimed.sessionId).get()).data();
   const obsolete=!session || (claimed.type==='Ready for Pickup'&&(session.status!=='Ready for Pickup'||session.pickupGeneration!==claimed.pickupGeneration)) || (['Schedule Confirmed','Schedule Changed','Schedule Reminder'].includes(claimed.type)&&session.version!==claimed.eventVersion);
   if(obsolete){await ref.update({state:'superseded'});return;}
 }
 for(const channel of ['push','sms']){
   if(!policy[channel])continue;
   const attempt={channel,atMs:Date.now(),recipient:claimed.contact.name};
   try{
     if(channel==='push'){
       // Generic lock-screen text. Exact authorized message remains in the app.
       attempt.message='DialyCare update: Open DialyCare to view your update.';
       attempt.providerId=await getMessaging().send({token:prefs.token,notification:{title:'DialyCare update',body:'Open DialyCare to view your update.'},data:{notificationId:ref.id,sessionId:claimed.sessionId||'',message:claimed.pushMessage}});
       attempt.outcome='accepted by FCM; delivery and reading unconfirmed';
     }else{
       attempt.message=claimed.smsMessage;
       const url=process.env.SMS_API_URL;
       if(!url||!url.startsWith('https://')||process.env.SMS_ADAPTER_CONFIRMED!=='true'){attempt.outcome='blocked: SMS provider adapter not configured';}
       else{
         // Provider-specific adapter contract must be verified before enabling.
         const response=await fetch(url,{method:'POST',headers:{Authorization:`Bearer ${smsKey.value()}`,'Content-Type':'application/json','Idempotency-Key':ref.id},body:JSON.stringify({to:claimed.contact.phone,message:claimed.smsMessage,clientReference:ref.id}),signal:AbortSignal.timeout(15000)});
         if(!response.ok)throw Error('SMS provider HTTP '+response.status);
         const result=await response.json();if(!result.messageId)throw Error('SMS response missing messageId; outcome unknown');
         attempt.providerId=String(result.messageId);attempt.outcome='accepted by SMS provider; delivery unconfirmed';
       }
     }
   }catch(e){attempt.outcome='failed or unknown; review before any retry';attempt.error=String(e.code||e.message).slice(0,240);
     if(channel==='push'&&['messaging/registration-token-not-registered','messaging/invalid-registration-token'].includes(e.code)&&claimed.recipientUid){await db.doc(`dcUsers/${claimed.recipientUid}/private/preferences`).set({token:'',pushEnabled:false},{merge:true});policy.sms=D.channels(claimed.contact,{...prefs,token:''},settings).sms;attempt.outcome='rejected: invalid push token';}
   }
   attempts.push(attempt);await ref.update({attempts:FieldValue.arrayUnion(attempt)});
 }
 await ref.update({state:attempts.length?'attempted':'blocked: no eligible channel',finishedMs:Date.now()});
});
exports.reminderSweep=onSchedule({schedule:'every 5 minutes',region,timeZone:'Asia/Manila'},async()=>{
 const centers=await db.collection('dcCenters').get(),now=Date.now();
 for(const c of centers.docs){const root=c.ref;
   const candidates=await root.collection('sessions').get();
   for(const doc of candidates.docs)await db.runTransaction(async tx=>{
     const snap=await tx.get(doc.ref),s={id:doc.id,...snap.data()},settings=c.data();
     const type=s.status==='Scheduled'&&s.startMs>now&&s.startMs-now<=(settings.reminderMinutes||60)*60000?'Schedule Reminder':s.status==='In Progress'&&s.endMs>now&&s.endMs-now<=10*60000?'Session Ending Soon':null;
     if(s.status==='Ready for Pickup'&&!s.escalated&&now>=s.escalationDueMs){tx.update(doc.ref,{escalationNeeded:true});return;}
     if(!type)return;
     const marker=root.collection('reminders').doc(`${doc.id}-${s.version}-${type.replaceAll(' ','_')}`);
     const [existing,p,t]=await Promise.all([tx.get(marker),tx.get(root.collection('patients').doc(s.patientId)),tx.get(root.collection('templates'))]);
     if(existing.exists||!p.exists)return;
     notify(tx,root,s,p.data(),type,now,Object.fromEntries(t.docs.map(x=>[x.id,x.data()])),settings);
     tx.create(marker,{atMs:now});
   });
   // A crash after provider acceptance must be visible, not silently retried.
   const stuck=await root.collection('notifications').where('state','==','sending').get();
   for(const n of stuck.docs)if(now-n.data().claimedMs>600000)await n.ref.update({state:'unknown: worker interrupted; reconcile provider before retry'});
 }
});


