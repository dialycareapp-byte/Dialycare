'use strict';
// Explicit administrator action: node provision-user.cjs EXISTING_UID CENTER_ID ROLE
const {initializeApp,applicationDefault}=require('firebase-admin/app');const {getFirestore}=require('firebase-admin/firestore');const {getAuth}=require('firebase-admin/auth');
const [uid,centerId,role]=process.argv.slice(2);
if(!uid||!centerId||!['admin','staff','patient','relative'].includes(role)){console.error('Usage: node provision-user.cjs EXISTING_UID CENTER_ID ROLE');process.exit(1);}
initializeApp({credential:applicationDefault(),projectId:process.env.GOOGLE_CLOUD_PROJECT});
(async()=>{await getAuth().getUser(uid);const db=getFirestore();await db.runTransaction(async tx=>{const ref=db.doc('dcUsers/'+uid),old=await tx.get(ref);tx.set(ref,{active:true,centerId,role});tx.create(db.collection('dcCenters').doc(centerId).collection('audit').doc(),{action:'provisionUser',actorUid:'administrator-cli',recordId:uid,before:old.data()||null,after:{active:true,centerId,role},atMs:Date.now()});});console.log('Provisioned existing account.');process.exit(0);})().catch(e=>{console.error(e.message);process.exit(1);});
