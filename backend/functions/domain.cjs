'use strict';
const transitions = {
  Scheduled:['Waiting','Missed','Cancelled'], Waiting:['In Progress','Missed','Cancelled'],
  'In Progress':['Completed'], Completed:['Ready for Pickup'], 'Ready for Pickup':['Picked Up'],
  'Picked Up':[], Missed:[], Cancelled:[]
};
function requireRole(profile, roles) {
  if (!profile || profile.active !== true || !roles.includes(profile.role)) throw Error('Not authorized for this action.');
}
function validateSchedule(v, others, id) {
  if (!Number.isSafeInteger(v.startMs)||!Number.isSafeInteger(v.endMs)||v.startMs<=0||v.endMs<=v.startMs||v.endMs-v.startMs>43200000) throw Error('Invalid appointment duration (maximum 12 hours).');
  if (!['Batch A','Batch B','Batch C'].includes(v.batch)||typeof v.room!=='string'||!v.room.trim()) throw Error('Choose a batch and room.');
  const room=x=>String(x||'').trim().toLowerCase().replace(/\s+/g,' ');
  if (others.some(s=>s.id!==id&&!['Cancelled','Missed'].includes(s.status)&&s.startMs<v.endMs&&s.endMs>v.startMs&&(room(s.room)===room(v.room)||s.patientId===v.patientId))) throw Error('Patient or room overlaps an existing appointment.');
}
function assertTransition(from,to) { if (!transitions[from]?.includes(to)) throw Error('Invalid session transition.'); }
function canEscalate(s, now, minutes) { return s.status==='Ready for Pickup'&&!s.escalated&&(s.pickupResponse==='Cannot Pick Up'||now-s.pickupRequestedMs>=minutes*60000); }
function channels(contact, prefs={}, policy={}) {
  const validPush=!!contact.uid && !!prefs.token && prefs.pushEnabled!==false;
  const smsEligible=contact.phoneVerified===true&&contact.smsConsent===true&&/^\+[1-9]\d{7,14}$/.test(contact.phone||'');
  // Silence is NOT push failure. Only explicit configured channel rules apply.
  return {push:validPush&&prefs.preferredChannel!=='sms', sms:smsEligible&&(prefs.preferredChannel==='sms'||!validPush||policy.smsAlways===true)};
}
const templateNames=['Schedule Confirmed','Schedule Reminder','Schedule Changed','Session Started','Session Ending Soon','Session Completed','Ready for Pickup','Pickup Confirmed','Center Announcements'];
const defaults=Object.fromEntries(templateNames.map(n=>[n,{push:`{name}: ${n} at {center}. {date}`,sms:`{center}: ${n}. Please check the app or contact the center. {date}`} ]));
function render(template, values) { return template.replace(/\{(name|date|center)\}/g,(_,k)=>String(values[k]||'')); }
function day(ms){return new Date(ms+8*3600000).toISOString().slice(0,10);}
module.exports={transitions,requireRole,validateSchedule,assertTransition,canEscalate,channels,defaults,templateNames,render,day};
