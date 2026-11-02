import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FileDownloader().start(autoCleanDatabase: false);
  FileDownloader().configureNotification(
    running: const TaskNotification('ONIDL Go downloading', '{filename} • {progress}'),
    complete: const TaskNotification('Download complete', '{filename}'),
    error: const TaskNotification('Download failed', '{filename}'),
    progressBar: true,
    tapOpensFile: true,
  );
  runApp(const OnidlGoApp());
}

const accent = Color(0xFF7183FF);
const mint = Color(0xFF40D9B0);

class FreeSearchItem {
  const FreeSearchItem({required this.title,required this.url,required this.source,required this.details,required this.detailsUrl,this.size});
  final String title,url,source,details,detailsUrl;
  final int? size;
}

class OnidlGoApp extends StatefulWidget {
  const OnidlGoApp({super.key});
  @override State<OnidlGoApp> createState()=>_OnidlGoAppState();
}
class _OnidlGoAppState extends State<OnidlGoApp> {
  ThemeMode mode=ThemeMode.dark;
  @override void initState(){super.initState();_loadTheme();}
  Future<void> _loadTheme() async {
    final prefs=await SharedPreferences.getInstance();
    if(!mounted)return;
    setState(()=>mode=prefs.getBool('lightTheme')==true?ThemeMode.light:ThemeMode.dark);
  }
  Future<void> _setTheme(bool light) async {
    setState(()=>mode=light?ThemeMode.light:ThemeMode.dark);
    final prefs=await SharedPreferences.getInstance();
    await prefs.setBool('lightTheme',light);
  }
  @override Widget build(BuildContext context)=>MaterialApp(
    title:'ONIDL Go',debugShowCheckedModeBanner:false,themeMode:mode,
    theme:ThemeData(colorScheme:ColorScheme.fromSeed(seedColor:accent,brightness:Brightness.light),useMaterial3:true),
    darkTheme:ThemeData(colorScheme:ColorScheme.fromSeed(seedColor:accent,brightness:Brightness.dark,surface:const Color(0xFF080D1B)),scaffoldBackgroundColor:const Color(0xFF080D1B),useMaterial3:true),
    home:MainShell(isLight:mode==ThemeMode.light,onTheme:_setTheme),
  );
}

class MainShell extends StatefulWidget {
  const MainShell({super.key,required this.isLight,required this.onTheme});
  final bool isLight; final ValueChanged<bool> onTheme;
  @override State<MainShell> createState()=>_MainShellState();
}
class _MainShellState extends State<MainShell> {
  int tab=0;
  static const MethodChannel torrentChannel=MethodChannel('com.onidl.go/torrent');
  static const EventChannel torrentEventsChannel=EventChannel('com.onidl.go/torrent_events');
  late final Stream<List<dynamic>> torrentEvents;
  final urlController=TextEditingController();
  final searchController=TextEditingController();
  String searchProvider='Internet Archive';
  bool searching=false;
  List<FreeSearchItem> searchResults=[];
  List<FileSystemEntity> saved=[];
  bool loading=false;
  List<Map<String,String>> feedbackEntries=[];
  @override void initState(){super.initState();torrentEvents=torrentEventsChannel.receiveBroadcastStream().map((event)=>(event as List).cast<dynamic>());_refreshFiles();_loadFeedback();}
  @override void dispose(){urlController.dispose();searchController.dispose();super.dispose();}
  void toast(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
  Future<void> _loadFeedback() async {
    final prefs=await SharedPreferences.getInstance();
    final raw=prefs.getStringList('localFeedback')??[];
    feedbackEntries=raw.map((v){try{final m=jsonDecode(v) as Map<String,dynamic>;return {'name':'${m['name']??''}','description':'${m['description']??''}','date':'${m['date']??''}'};}catch(_){return <String,String>{};}}).where((m)=>m.isNotEmpty).toList();
    if(mounted)setState((){});
  }
  Future<Directory> _downloadDir() async {
    final docs=await getApplicationDocumentsDirectory();
    final dir=Directory('${docs.path}/ONIDL Go');
    if(!await dir.exists()) await dir.create(recursive:true);
    return dir;
  }
  Future<void> _refreshFiles() async {
    final d=await _downloadDir();
    saved=d.listSync(recursive:true).whereType<File>().toList()..sort((a,b)=>b.statSync().modified.compareTo(a.statSync().modified));
    if(mounted)setState((){});
  }
  String _safeName(String name) {
    final cleaned=name.replaceAll(RegExp(r'[\\/:*?"<>|]'),'_').trim();
    return cleaned.isEmpty?'download_${DateTime.now().millisecondsSinceEpoch}':cleaned;
  }
  Future<void> _addDownload(String raw) async {
    final uri=Uri.tryParse(raw.trim());
    if(uri!=null && uri.scheme=='magnet') {
      try {
        final dir=await _downloadDir();
        await torrentChannel.invokeMethod<bool>('addMagnet',{'magnet':raw.trim(),'savePath':dir.path});
        urlController.clear();toast('Magnet link added to Torrent Engine.');return;
      } catch(e) {toast('Could not add magnet link: $e');return;}
    }
    if(uri==null||!uri.hasScheme||!['http','https'].contains(uri.scheme)||uri.host.isEmpty){toast('Enter a valid HTTP/HTTPS URL or magnet link.');return;}
    final filename=_safeName(uri.pathSegments.isEmpty?'download':Uri.decodeComponent(uri.pathSegments.last));
    try {
      final task=DownloadTask(
        url:uri.toString(),
        filename:filename,
        directory:'ONIDL Go',
        baseDirectory:BaseDirectory.applicationDocuments,
        retries:3,
        allowPause:true,
        transferHints:{TransferHint.userInitiated,TransferHint.largeFile},
      );
      await FileDownloader().transfers.start(task);
      urlController.clear();
      if(mounted)setState(()=>tab=2);
      toast('Download added. It can continue in the background.');
    } catch(e) {toast('Could not start download: $e');}
  }
  Future<void> _importTorrent() async {
    final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['torrent'],withData:true);
    if(result==null)return;
    final bytes=result.files.single.bytes;
    if(bytes==null||bytes.isEmpty){toast('Could not read the selected torrent file.');return;}
    try {
      final dir=await _downloadDir();
      await torrentChannel.invokeMethod<bool>('addTorrentBytes',{'bytes':bytes,'savePath':dir.path});
      toast('Torrent added to Torrent Engine.');
    } catch(e) {toast('Could not add torrent: $e');}
  }
  Future<void> _searchFreeLibrary() async {
    final q=searchController.text.trim();
    if(q.isEmpty){toast('Enter something to search.');return;}
    setState((){searching=true;searchResults=[];});
    try {
      if(searchProvider=='Internet Archive') {
        final uri=Uri.https('archive.org','/advancedsearch.php',{
          'q':q,'fl[]':'identifier,title,creator,mediatype','rows':'12','page':'1','output':'json'
        });
        final response=await http.get(uri,headers:{'User-Agent':'ONIDL-Go/1.0'}).timeout(const Duration(seconds:25));
        if(response.statusCode!=200) throw Exception('Internet Archive returned ${response.statusCode}');
        final decoded=jsonDecode(response.body) as Map<String,dynamic>;
        final docs=((decoded['response'] as Map<String,dynamic>)['docs'] as List).cast<Map<String,dynamic>>();
        final items=await Future.wait(docs.take(10).map((doc)=>_archiveItem(doc)));
        searchResults=items.whereType<FreeSearchItem>().toList();
      } else {
        final uri=Uri.https('commons.wikimedia.org','/w/api.php',{
          'action':'query','generator':'search','gsrsearch':'filetype:bitmap $q','gsrnamespace':'6','gsrlimit':'20',
          'prop':'imageinfo','iiprop':'url|size','iiurlwidth':'1200','format':'json','origin':'*'
        });
        final response=await http.get(uri,headers:{'User-Agent':'ONIDL-Go/1.0 (free media search)'}).timeout(const Duration(seconds:25));
        if(response.statusCode!=200) throw Exception('Wikimedia Commons returned ${response.statusCode}');
        final decoded=jsonDecode(response.body) as Map<String,dynamic>;
        final pages=((decoded['query'] as Map<String,dynamic>?)?['pages'] as Map<String,dynamic>?) ?? {};
        searchResults=pages.values.map((raw){
          final page=raw as Map<String,dynamic>;
          final info=(page['imageinfo'] as List?)?.first as Map<String,dynamic>?;
          final direct=info?['url'] as String?;
          if(direct==null)return null;
          return FreeSearchItem(title:(page['title'] as String? ?? 'Media file').replaceFirst('File:',''),url:direct,source:'Wikimedia Commons',size:info?['size'] as int?,details:'Free media • Check the file page for its license and attribution requirements',detailsUrl:'https://commons.wikimedia.org/wiki/${Uri.encodeComponent(page['title'] as String? ?? '')}');
        }).whereType<FreeSearchItem>().toList();
      }
      if(mounted)setState((){});
      if(searchResults.isEmpty)toast('No downloadable results found. Try another search.');
    } catch(e) {toast('Search failed: $e');}
    finally {if(mounted)setState(()=>searching=false);}
  }
  Future<FreeSearchItem?> _archiveItem(Map<String,dynamic> doc) async {
    final id=doc['identifier'] as String?;
    if(id==null||id.isEmpty)return null;
    try {
      final uri=Uri.https('archive.org','/metadata/$id');
      final response=await http.get(uri).timeout(const Duration(seconds:20));
      if(response.statusCode!=200)return null;
      final metadata=jsonDecode(response.body) as Map<String,dynamic>;
      final files=(metadata['files'] as List?)?.whereType<Map<String,dynamic>>().where((f){
        final name=f['name'] as String? ?? '';
        return name.isNotEmpty && f['private']!=true && f['private']!='true' && !name.endsWith('_meta.xml') && !name.endsWith('_files.xml') && !name.endsWith('.torrent') && f['source']!='metadata';
      }).toList() ?? [];
      if(files.isEmpty)return null;
      files.sort((a,b){
        int score(Map<String,dynamic> f){final n=(f['name'] as String? ?? '').toLowerCase();final fmt=(f['format'] as String? ?? '').toLowerCase();if(fmt.contains('mpeg4')||n.endsWith('.mp4'))return 0;if(fmt.contains('pdf')||n.endsWith('.pdf'))return 1;if(fmt.contains('mp3')||n.endsWith('.mp3'))return 2;if(fmt.contains('epub')||n.endsWith('.epub'))return 3;return 4;}
        return score(a).compareTo(score(b));
      });
      final file=files.first;
      final filename=file['name'] as String;
      final direct='https://archive.org/download/${Uri.encodeComponent(id)}/${filename.split('/').map(Uri.encodeComponent).join('/')}';
      final creator=doc['creator'];
      return FreeSearchItem(title:doc['title'] as String? ?? id,url:direct,source:'Internet Archive',size:int.tryParse('${file['size'] ?? ''}'),details:'${doc['mediatype'] ?? 'Archive item'}${creator==null?'':' • $creator'} • ${file['format'] ?? 'File'}',detailsUrl:'https://archive.org/details/${Uri.encodeComponent(id)}');
    } catch(_){return null;}
  }
  Future<void> _downloadSearchItem(FreeSearchItem item) async {
    final uri=Uri.tryParse(item.url);
    if(uri==null){toast('Invalid download link.');return;}
    final filename=_safeName(Uri.decodeComponent(uri.pathSegments.isEmpty?'download':uri.pathSegments.last));
    try {
      final task=DownloadTask(url:item.url,filename:filename,directory:'ONIDL Go',baseDirectory:BaseDirectory.applicationDocuments,retries:3,allowPause:true,transferHints:{TransferHint.userInitiated,TransferHint.largeFile});
      await FileDownloader().transfers.start(task);
      if(mounted){setState(()=>tab=2);toast('Download added.');}
    } catch(e){toast('Could not start download: $e');}
  }
  Future<void> _torrentControl(String method) async {
    try {await torrentChannel.invokeMethod<bool>(method);toast(method=='pauseAllTorrents'?'Torrent downloads paused.':'Torrent downloads resumed.');}
    catch(e){toast('Torrent control failed: $e');}
  }
  Future<void> _torrentItemControl(String id,String method) async {
    try {await torrentChannel.invokeMethod<bool>(method,{'id':id});}
    catch(e){toast('Torrent control failed: $e');}
  }
  Future<void> _pause(Transfer t) async {try{await t.pause();}catch(e){toast('Pause unavailable: $e');}}
  Future<void> _resume(Transfer t) async {try{await t.resume();}catch(e){toast('Resume unavailable: $e');}}
  Future<void> _cancel(Transfer t) async {try{await t.cancel();}catch(e){toast('Cancel failed: $e');}}
  Future<void> _retry(Transfer t) async {
    final task=t.task;
    try {
      final retry=DownloadTask(url:task.url,filename:task.filename,directory:'ONIDL Go',baseDirectory:BaseDirectory.applicationDocuments,retries:3,allowPause:true,transferHints:{TransferHint.userInitiated,TransferHint.largeFile});
      await FileDownloader().transfers.start(retry);
      toast('Retry started.');
    } catch(e){toast('Retry failed: $e');}
  }
  String _formatBytes(num bytes) {
    if(bytes<0)return 'Unknown size';
    if(bytes<1024)return '${bytes.toStringAsFixed(0)} B';
    if(bytes<1048576)return '${(bytes/1024).toStringAsFixed(1)} KB';
    if(bytes<1073741824)return '${(bytes/1048576).toStringAsFixed(1)} MB';
    return '${(bytes/1073741824).toStringAsFixed(2)} GB';
  }
  String _status(Transfer t)=>t.statusNotifier.value.toString().split('.').last;
  Widget _header(String title,String subtitle,{Widget? trailing})=>Padding(padding:const EdgeInsets.fromLTRB(20,18,20,12),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:26,fontWeight:FontWeight.w800)),const SizedBox(height:4),Text(subtitle,style:TextStyle(color:Theme.of(context).colorScheme.onSurfaceVariant))])),if(trailing!=null)trailing]));
  @override Widget build(BuildContext context) {
    final pages=[_home(),_search(),_downloads(),_files(),_settings()];
    return Scaffold(body:SafeArea(child:pages[tab]),bottomNavigationBar:NavigationBar(
      selectedIndex:tab==4?0:tab,onDestinationSelected:(v)=>setState(()=>tab=v),
      destinations:const[
        NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'Home'),
        NavigationDestination(icon:Icon(Icons.search),label:'Search'),
        NavigationDestination(icon:Icon(Icons.download_outlined),selectedIcon:Icon(Icons.download),label:'Downloads'),
        NavigationDestination(icon:Icon(Icons.folder_outlined),selectedIcon:Icon(Icons.folder),label:'My Files'),
      ]));
  }
  Widget _home()=>ListView(padding:const EdgeInsets.only(bottom:24),children:[
    _header('ONIDL Go','Your downloads, one place',trailing:IconButton(onPressed:()=>setState(()=>tab=4),icon:const Icon(Icons.settings_outlined))),
    Padding(padding:const EdgeInsets.symmetric(horizontal:18),child:Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF273B82),Color(0xFF542E87)]),borderRadius:BorderRadius.circular(24)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Icon(Icons.rocket_launch_rounded,size:34,color:Colors.white),const SizedBox(height:16),
      const Text('Download anything.\nKeep it organized.',style:TextStyle(color:Colors.white,fontSize:24,fontWeight:FontWeight.bold)),
      const SizedBox(height:8),const Text('Paste a direct file link or magnet link to get started.',style:TextStyle(color:Colors.white70)),const SizedBox(height:18),
      FilledButton.icon(onPressed:()=>setState(()=>tab=1),icon:const Icon(Icons.search),label:const Text('Open Search'))
    ]))),
    Padding(padding:const EdgeInsets.fromLTRB(20,24,20,10),child:Text('Quick access',style:Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight:FontWeight.bold))),
    Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[
      _quick(Icons.download,'Downloads','${FileDownloader().transfers.all().length} items',2),const SizedBox(width:10),_quick(Icons.folder,'My Files','${saved.length} files',3)
    ])),
    Padding(padding:const EdgeInsets.all(18),child:Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Theme.of(context).cardColor,borderRadius:BorderRadius.circular(18)),child:const Row(children:[Icon(Icons.shield_outlined,color:mint),SizedBox(width:12),Expanded(child:Text('Use trusted links and download files you have permission to access. ONIDL Go does not provide antivirus protection.'))])))
  ]);
  Widget _quick(IconData icon,String title,String sub,int destination)=>Expanded(child:InkWell(onTap:()=>setState(()=>tab=destination),borderRadius:BorderRadius.circular(18),child:Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Theme.of(context).cardColor,borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(icon,color:accent,size:26),const SizedBox(height:14),Text(title,style:const TextStyle(fontWeight:FontWeight.bold)),Text(sub,style:Theme.of(context).textTheme.bodySmall)]))));
  Widget _search()=>ListView(padding:const EdgeInsets.only(bottom:24),children:[
    _header('Search & Download','Free and legal file sources'),
    Padding(padding:const EdgeInsets.symmetric(horizontal:18),child:TextField(controller:searchController,textInputAction:TextInputAction.search,onSubmitted:(_)=>_searchFreeLibrary(),decoration:InputDecoration(hintText:'Search free books, videos, audio, images…',prefixIcon:const Icon(Icons.search),filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none)))),
    Padding(padding:const EdgeInsets.fromLTRB(18,10,18,4),child:Row(children:[Expanded(child:DropdownButtonFormField<String>(value:searchProvider,decoration:const InputDecoration(labelText:'Search source',border:OutlineInputBorder()),items:const [DropdownMenuItem(value:'Internet Archive',child:Text('Internet Archive')),DropdownMenuItem(value:'Wikimedia Commons',child:Text('Wikimedia Commons'))],onChanged:(v){if(v!=null)setState(()=>searchProvider=v);})),const SizedBox(width:10),FilledButton(onPressed:searching?null:_searchFreeLibrary,child:searching?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Text('Search'))])),
    if(searching)const Padding(padding:EdgeInsets.all(24),child:Center(child:CircularProgressIndicator())),
    if(!searching&&searchResults.isEmpty)Padding(padding:const EdgeInsets.all(18),child:Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:Theme.of(context).cardColor,borderRadius:BorderRadius.circular(18)),child:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Free search providers',style:TextStyle(fontWeight:FontWeight.bold,fontSize:16)),SizedBox(height:8),Text('Search files from Internet Archive and Wikimedia Commons. Rights and licenses vary by item; open the source page and confirm reuse permissions before downloading or sharing. No API key is required.'),SizedBox(height:8),Text('You can also paste a direct HTTP/HTTPS link or a magnet link below.')]))),
    if(searchResults.isNotEmpty)Padding(padding:const EdgeInsets.fromLTRB(18,14,18,6),child:Text('${searchResults.length} results',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.bold))),
    ...searchResults.map((item)=>Card(margin:const EdgeInsets.symmetric(horizontal:16,vertical:5),child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(item.title,style:const TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:5),Text(item.details,style:Theme.of(context).textTheme.bodySmall),const SizedBox(height:4),Text('${item.source} • ${item.size==null?'Size unknown':_formatBytes(item.size!)}',style:Theme.of(context).textTheme.bodySmall),Row(mainAxisAlignment:MainAxisAlignment.end,children:[TextButton(onPressed:()=>launchUrl(Uri.parse(item.detailsUrl),mode:LaunchMode.externalApplication),child:const Text('Source & license')),FilledButton.tonalIcon(onPressed:()=>_downloadSearchItem(item),icon:const Icon(Icons.download),label:const Text('Download'))])])))),
    const Divider(height:28),
    Padding(padding:const EdgeInsets.symmetric(horizontal:18),child:Text('Direct link download',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.bold))),
    Padding(padding:const EdgeInsets.fromLTRB(18,10,18,4),child:TextField(controller:urlController,keyboardType:TextInputType.url,decoration:InputDecoration(hintText:'Paste HTTP / HTTPS URL or magnet link',prefixIcon:const Icon(Icons.link),suffixIcon:IconButton(icon:const Icon(Icons.clear),onPressed:urlController.clear),filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none)))),
    Padding(padding:const EdgeInsets.fromLTRB(18,8,18,4),child:FilledButton.icon(onPressed:()=>_addDownload(urlController.text),icon:const Icon(Icons.download),label:const Text('Download link'))),
    Padding(padding:const EdgeInsets.symmetric(horizontal:18,vertical:6),child:OutlinedButton.icon(onPressed:_importTorrent,icon:const Icon(Icons.file_open),label:const Text('Import .torrent file'))),
  ]);
  Widget _downloads()=>Column(children:[
    _header('Downloads','Background transfers',trailing:IconButton(onPressed:()=>setState(()=>tab=1),icon:const Icon(Icons.add))),
    Padding(padding:const EdgeInsets.fromLTRB(16,0,16,10),child:Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>_torrentControl('pauseAllTorrents'),icon:const Icon(Icons.pause),label:const Text('Pause torrents'))),const SizedBox(width:10),Expanded(child:OutlinedButton.icon(onPressed:()=>_torrentControl('resumeAllTorrents'),icon:const Icon(Icons.play_arrow),label:const Text('Resume torrents')))])),
    Expanded(child:StreamBuilder<List<dynamic>>(stream:torrentEvents,builder:(context,torrentSnapshot)=>ValueListenableBuilder<List<Transfer>>(valueListenable:FileDownloader().transfers.notifier,builder:(context,items,_) {
      final torrents=torrentSnapshot.data??const <dynamic>[];
      if(items.isEmpty&&torrents.isEmpty)return _empty(Icons.download,'No downloads yet','Paste a direct file link or add a magnet / .torrent file to begin.');
      return ListView(padding:const EdgeInsets.fromLTRB(16,0,16,20),children:[
        if(torrents.isNotEmpty)Padding(padding:const EdgeInsets.only(bottom:8),child:Text('Torrent downloads',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.bold))),
        ...torrents.map((raw)=>_torrentCard(Map<String,dynamic>.from(raw as Map))),
        if(items.isNotEmpty)Padding(padding:const EdgeInsets.fromLTRB(0,14,0,8),child:Text('Direct downloads',style:Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight:FontWeight.bold))),
        ...items.map(_transferCard),
      ]);
    })))
  ]);
  Widget _torrentCard(Map<String,dynamic> torrent)=>Card(margin:const EdgeInsets.only(bottom:12),child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[const Icon(Icons.swap_vert_circle_outlined,color:accent),const SizedBox(width:10),Expanded(child:Text('${torrent['name']??'Torrent'}',maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold))),Text(torrent['finished']==true?'Complete':(torrent['paused']==true?'Paused':'${((torrent['progress'] as num? ?? 0)*100).toStringAsFixed(1)}%'),style:TextStyle(color:torrent['finished']==true?mint:Theme.of(context).colorScheme.secondary,fontSize:12))]),
    const SizedBox(height:12),LinearProgressIndicator(value:((torrent['progress'] as num?)?.toDouble()??0).clamp(0.0,1.0).toDouble(),minHeight:6,borderRadius:BorderRadius.circular(8)),
    const SizedBox(height:8),Wrap(spacing:14,runSpacing:4,children:[Text('Down: ${_formatBytes((torrent['downloadRate'] as num? ?? 0).toDouble())}/s',style:Theme.of(context).textTheme.bodySmall),Text('Up: ${_formatBytes((torrent['uploadRate'] as num? ?? 0).toDouble())}/s',style:Theme.of(context).textTheme.bodySmall),Text('Peers: ${torrent['peers']??0}',style:Theme.of(context).textTheme.bodySmall),Text('${_formatBytes((torrent['downloaded'] as num? ?? 0).toDouble())} / ${_formatBytes((torrent['total'] as num? ?? 0).toDouble())}',style:Theme.of(context).textTheme.bodySmall)]),
    const SizedBox(height:6),Text('${torrent['state']??'Checking'}',style:Theme.of(context).textTheme.bodySmall),
    Row(mainAxisAlignment:MainAxisAlignment.end,children:[
      if(torrent['paused']==true)IconButton(tooltip:'Resume',onPressed:()=>_torrentItemControl('${torrent['id']}','resumeTorrent'),icon:const Icon(Icons.play_circle_outline)),
      if(torrent['paused']!=true&&torrent['finished']!=true)IconButton(tooltip:'Pause',onPressed:()=>_torrentItemControl('${torrent['id']}','pauseTorrent'),icon:const Icon(Icons.pause_circle_outline)),
    ])
  ])));
  Widget _transferCard(Transfer t)=>Card(margin:const EdgeInsets.only(bottom:12),child:Padding(padding:const EdgeInsets.all(14),child:ValueListenableBuilder<double?>(valueListenable:t.progressNotifier,builder:(context,progress,_)=>ValueListenableBuilder<TaskStatus>(valueListenable:t.statusNotifier,builder:(context,status,__)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[const Icon(Icons.insert_drive_file_outlined,color:accent),const SizedBox(width:10),Expanded(child:Text(t.task.filename,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold))),Text(status.toString().split('.').last,style:TextStyle(color:status==TaskStatus.complete?mint:Theme.of(context).colorScheme.secondary,fontSize:12))]),
    const SizedBox(height:12),LinearProgressIndicator(value:progress,minHeight:6,borderRadius:BorderRadius.circular(8)),
    const SizedBox(height:8),Row(children:[Expanded(child:Text(progress==null?'Progress unavailable':'${(progress*100).toStringAsFixed(1)}%',style:Theme.of(context).textTheme.bodySmall)),Text('${t.networkSpeedNotifier.value.toStringAsFixed(2)} MB/s',style:Theme.of(context).textTheme.bodySmall)]),
    const SizedBox(height:8),Row(mainAxisAlignment:MainAxisAlignment.end,children:[
      if(status==TaskStatus.running)IconButton(tooltip:'Pause',onPressed:()=>_pause(t),icon:const Icon(Icons.pause_circle_outline)),
      if(status==TaskStatus.paused||status==TaskStatus.enqueued)IconButton(tooltip:'Resume',onPressed:()=>_resume(t),icon:const Icon(Icons.play_circle_outline)),
      if(status==TaskStatus.failed||status==TaskStatus.canceled)IconButton(tooltip:'Retry',onPressed:()=>_retry(t),icon:const Icon(Icons.refresh)),
      if(status!=TaskStatus.complete&&status!=TaskStatus.canceled)IconButton(tooltip:'Cancel',onPressed:()=>_cancel(t),icon:const Icon(Icons.cancel_outlined)),
    ])
  ])))));
  String _fileFormat(String path){final ext=path.contains('.')?path.split('.').last.toUpperCase():'FILE';return ext.length>8?'FILE':ext;}
  Widget _files()=>Column(children:[
    _header('My Files','Only files saved by ONIDL Go',trailing:IconButton(onPressed:_refreshFiles,icon:const Icon(Icons.refresh))),
    Expanded(child:saved.isEmpty?_empty(Icons.folder_open,'No files yet','Completed downloads will appear here.'):ListView.builder(itemCount:saved.length,itemBuilder:(c,i){final f=saved[i] as File;return ListTile(leading:const Icon(Icons.insert_drive_file,color:accent),title:Text(f.uri.pathSegments.last,maxLines:1,overflow:TextOverflow.ellipsis),subtitle:Text('${_formatBytes(f.lengthSync())} • ${_fileFormat(f.path)} • Not scanned'),onTap:()=>OpenFilex.open(f.path),trailing:PopupMenuButton<String>(onSelected:(v)async{if(v=='open')OpenFilex.open(f.path);if(v=='delete'){await f.delete();await _refreshFiles();}},itemBuilder:(_)=>const [PopupMenuItem(value:'open',child:Text('Open')),PopupMenuItem(value:'delete',child:Text('Delete'))]))}))
  ]);
  Widget _settings()=>ListView(children:[
    _header('Settings','Make ONIDL Go yours'),
    SwitchListTile(title:const Text('Light theme'),subtitle:const Text('Use a bright appearance'),value:widget.isLight,onChanged:widget.onTheme),
    const ListTile(leading:Icon(Icons.notifications_active_outlined),title:Text('Download notifications'),subtitle:Text('Android may ask for notification permission when the first download starts.')),
    const ListTile(leading:Icon(Icons.wifi_outlined),title:Text('Network'),subtitle:Text('Background transfers use Android WorkManager / system transfer scheduling.')),
    ListTile(leading:const Icon(Icons.feedback_outlined),title:const Text('Feedback'),subtitle:const Text('Public feedback sharing is not connected yet'),onTap:_feedback),
    const ListTile(leading:Icon(Icons.info_outline),title:Text('About ONIDL Go'),subtitle:Text('No ads. Free and open-source components.')),
    const Padding(padding:EdgeInsets.all(18),child:Text('Version 1.0.0 • Development build',textAlign:TextAlign.center))
  ]);
  Future<void> _feedback()async{
    final n=TextEditingController(),d=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('Feedback'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:n,maxLength:40,decoration:const InputDecoration(labelText:'Name')),TextField(controller:d,maxLength:1000,maxLines:4,decoration:const InputDecoration(labelText:'Description'))])),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Close')),FilledButton(onPressed:()async{
      final name=n.text.trim(),description=d.text.trim();
      if(name.isEmpty||description.isEmpty){toast('Enter your name and feedback description.');return;}
      final entry={'name':name,'description':description,'date':DateTime.now().toIso8601String()};
      final prefs=await SharedPreferences.getInstance();
      final list=prefs.getStringList('localFeedback')??[];
      list.insert(0,jsonEncode(entry));
      await prefs.setStringList('localFeedback',list.take(100).toList());
      if(!mounted)return;
      Navigator.pop(c);await _loadFeedback();toast('Feedback saved on this device. Public sharing is not connected.');
    },child:const Text('Save'))]));
    n.dispose();d.dispose();
    if(!mounted)return;
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('Saved feedback'),content:SizedBox(width:double.maxFinite,child:feedbackEntries.isEmpty?const Text('No feedback saved yet.'):ListView(shrinkWrap:true,children:feedbackEntries.map((e)=>ListTile(title:Text(e['name']??''),subtitle:Text(e['description']??''),dense:true)).toList())),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Close'))]));
  }
  Widget _empty(IconData icon,String title,String desc)=>Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(icon,size:54,color:Theme.of(context).colorScheme.outline),const SizedBox(height:14),Text(title,style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),const SizedBox(height:6),Text(desc,textAlign:TextAlign.center,style:Theme.of(context).textTheme.bodyMedium)])));
}
