'use strict';
// Read-only schema inventory. Requires authorized Application Default Credentials.
const {initializeApp,applicationDefault}=require('firebase-admin/app');const {getFirestore}=require('firebase-admin/firestore');
initializeApp({credential:applicationDefault(),projectId:process.env.GOOGLE_CLOUD_PROJECT});
getFirestore().listCollections().then(c=>{console.log(c.map(x=>x.id).sort().join('\n'));process.exit(0);}).catch(e=>{console.error(e.message);process.exit(1);});
