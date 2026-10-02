import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'repository.dart';

class DialyCareLogo extends StatelessWidget {
  const DialyCareLogo({super.key,this.size=80});
  final double size;
  @override Widget build(BuildContext context) => ClipRRect(borderRadius:BorderRadius.circular(10),child:Image.asset('packages/core_shared/assets/dialycare_logo.jpg',width:size,height:size,fit:BoxFit.contain));
}
class AccessGate extends StatefulWidget {
  const AccessGate({super.key,required this.builder,this.mobile=false,this.initializationError});
  final Widget Function(CareRepository) builder;
  final bool mobile;
  final String? initializationError;
  @override State<AccessGate> createState()=>_AccessGateState();
}
class _AccessGateState extends State<AccessGate> {
  final email=TextEditingController(), password=TextEditingController();
  String role='patient'; String? error; bool busy=false; CareRepository? demo;
  @override void dispose(){ email.dispose(); password.dispose(); demo?.dispose(); super.dispose(); }
  Future<void> login() async {
    setState(()=>busy=true);
    try { await FirebaseAuth.instance.signInWithEmailAndPassword(email:email.text.trim(),password:password.text); password.clear(); }
    catch(e){if(mounted)setState(()=>error='Sign-in failed. Check your account and connection. $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context) {
    if(demo!=null) return Column(children:[Material(color:const Color(0xFFFFEEC0),child:SafeArea(bottom:false,child:Row(children:[const SizedBox(width:12),const Expanded(child:Text('DEMO • Local only. No messages are sent.')),TextButton(onPressed:(){setState((){demo?.dispose();demo=null;});},child:const Text('Exit demo'))]))),Expanded(child:widget.builder(demo!))]);
    if(widget.initializationError!=null) return _login(widget.initializationError);
    return StreamBuilder<User?>(stream:FirebaseAuth.instance.authStateChanges(),builder:(context,snap){
      if(snap.connectionState==ConnectionState.waiting)return const Scaffold(body:Center(child:CircularProgressIndicator()));
      if(snap.data==null)return _login(null);
      final user=snap.data!;
      return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:FirebaseFirestore.instance.collection('dcUsers').doc(user.uid).snapshots(),builder:(context,profile){
        if(profile.connectionState==ConnectionState.waiting)return const Scaffold(body:Center(child:CircularProgressIndicator()));
        final d=profile.data?.data() ?? <String,dynamic>{};
        final allowed=d['active']==true && (widget.mobile ? d['role']==role : ['staff','admin'].contains(d['role']));
        if(profile.hasError || !allowed || d['centerId']==null)return Scaffold(body:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Text('This account has not been authorized for this role and center. Ask your administrator.'),TextButton(onPressed:()=>FirebaseAuth.instance.signOut(),child:const Text('Sign out'))]))));
        return _RepositoryHost(key:ValueKey('${user.uid}-${d['role']}-${d['centerId']}'),uid:user.uid,role:d['role'],centerId:d['centerId'],builder:widget.builder);
      });
    });
  }
  Widget _login(String? setupError)=>Scaffold(backgroundColor:const Color(0xFFEFFEFF),body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(24),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Card(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[
    const DialyCareLogo(size:110),const SizedBox(height:16),Text(widget.mobile?'Welcome to DialyCare':'DialyCare Staff',style:Theme.of(context).textTheme.headlineSmall),const SizedBox(height:20),
    if(widget.mobile) DropdownButtonFormField<String>(initialValue:role,items:const [DropdownMenuItem(value:'patient',child:Text('Patient')),DropdownMenuItem(value:'relative',child:Text('Relative'))],onChanged:(v)=>setState(()=>role=v!),decoration:const InputDecoration(labelText:'Your role')),
    TextField(controller:email,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'Email')),
    TextField(controller:password,obscureText:true,decoration:const InputDecoration(labelText:'Password'),onSubmitted:(_)=>busy?null:login()),
    const SizedBox(height:20),if(error!=null||setupError!=null) Text(error??setupError!,style:const TextStyle(color:Colors.red)),
    FilledButton(onPressed:busy||setupError!=null?null:login,child:Text(busy?'Signing in…':'Sign in')),
    TextButton(onPressed:()=>setState(()=>demo=CareRepository.demo(role:widget.mobile?role:'admin')),child:const Text('Explore explicit demo')),
    const Text('Role selection does not grant access. Accounts and patient links are provisioned by your center.',textAlign:TextAlign.center,style:TextStyle(fontSize:12)),
  ])))))));
}
class _RepositoryHost extends StatefulWidget {
  const _RepositoryHost({super.key,required this.uid,required this.role,required this.centerId,required this.builder});
  final String uid,role,centerId; final Widget Function(CareRepository) builder;
  @override State<_RepositoryHost> createState()=>_RepositoryHostState();
}
class _RepositoryHostState extends State<_RepositoryHost>{
  late final repo=CareRepository.live(widget.uid,widget.role,widget.centerId);
  @override void dispose(){repo.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>widget.builder(repo);
}

