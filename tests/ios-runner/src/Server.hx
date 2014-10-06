import sys.net.*;
import haxe.io.*;
import sys.io.*;
import cpp.vm.*;

using StringTools;

class Server
{
	static var timeout_secs:Float;

	static function main()
	{
		new mcli.Dispatch(Sys.args()).dispatch(new ServerCmd());
	}

	public static function listen(cmd:ServerCmd, port:Int)
	{
		var proto = new Protocol(Bytes.ofString('teste')),
				sock = new Socket();

		timeout_secs = cmd.timeout;
		sock.setTimeout(5);
		sock.bind(new Host(cmd.host), port );
		trace('listening',port);
		sock.listen(5);

		var i = 0;
		while (true)
		{
			var s2 = sock.accept();
			var filename = DateTools.format(Date.now(), '%Y%m%d_%H%M%S-${i++}');
			var path = cmd.tmpDir + filename;
			var file = sys.io.File.write('${cmd.logDir}/$filename.log');
			try
			{
				s2.waitForRead();
				s2.setTimeout(timeout_secs);

				var data = proto.fromClient(s2.input, sys.io.File.write(path));
				Sys.putEnv('TARGET_FILENAME',path);
				Sys.putEnv('IOSTEST',"1");

				file.writeString('IP : ');
				file.writeString(s2.peer().host.toString() );
				file.writeString('\n\n');
				file.writeString(Std.string(data) );
				file.writeString('\n\n');

				trace('setuo');
				var setup = data.setup == null ? [] : [ for (s in data.setup) run('/bin/sh',['-c',s]) ];
				trace('main gui');
				var mainAppGui = (data.mainAppGui == null) ? null : launchGui( data.mainAppGui.appId, expand(data.mainAppGui.listenFileEnd) );
				trace('main shell');
				var mainAppShell = data.mainAppShell == null ? [] : [ for (s in data.mainAppShell) run('/bin/sh',['-c',s]) ];
				trace('cleanup');
				var cleanup = data.cleanup == null ? [] : [ for (s in data.cleanup) run('/bin/sh',['-c',s]) ];

				trace('send file');
				var sendFile = data.sendFile == null ? null : expand( data.sendFile );

				var meta = { setup:setup, mainAppGui:mainAppGui, mainAppShell:mainAppShell, cleanup:cleanup };
				file.writeString(Std.string(meta) );
				file.writeString('\n\n');
				proto.toClient(s2.output, meta, sendFile);
			}
			catch(e:Dynamic)
			{
				trace('error',e);
				file.writeString('error: ');
				file.writeString(Std.string(e));
				var stack = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
				file.writeString('\n\n');
				file.writeString(stack);
				trace(stack);
				s2.close();
			}

			try { file.close(); } catch(e:Dynamic) {}
			External.setScreenDim(0);
		}
	}

	static function expand(cmd:String)
	{
		var ret = new StringBuf();
		var i = -1,
				len = cmd.length;
		while ( ++i < len )
		{
			switch (cmd.fastCodeAt(i)) {
				case '$'.code:
					var end = switch(cmd.charCodeAt(i+1))
					{
						case '$'.code:
							ret.addChar('$'.code);
							i++;
							continue;
						case '{'.code:
							'}'.code;
						case _:
							0;
					};
					var name = new StringBuf();
					while ( ++i < len )
					{
						var code = cmd.fastCodeAt(i);
						if (! ((code >= 'a'.code && code <= 'z'.code) || (code >= 'A'.code && code <= 'Z'.code) || code == '_'.code) )
						{
							if (code != end)
								i--;
							break;
						} else {
							name.addChar(code);
						}
					}
					var r = Sys.getEnv(name.toString());
					if (r != null)
						ret.add(r);
				case code:
					ret.addChar(code);
			}
		}

		return ret.toString();
	}

	static function launchGui(appId:String, listenFileEnd:String)
	{
		if (sys.FileSystem.exists(listenFileEnd))
		{
			try {
				sys.FileSystem.deleteFile(listenFileEnd);
			} catch(e:Dynamic) {}
		}

		var err = External.mainLaunchApp(appId, false);
		if (err != null)
			return { out: 'Error while launching GUI app $appId: $err', exit: (1 << 20) + 2 };

		// listen to file
		var time = Date.now().getTime();
		while(true)
		{
			var now = Date.now().getTime();
			if ( (now - time) / 1000 > timeout_secs )
				return { out: 'GUI app $appId timed out: ${ Std.int( (now - time) / 1000 ) } secs', exit: (1 << 20) + 1 };
			if (sys.FileSystem.exists(listenFileEnd))
				break;

			Sys.sleep(.2);
		}

		return { out:"", exit: 0 };
	}

	static function run(cmd:String, args:Array<String>):{ out:String, exit:Int }
	{
		var out = new StringBuf();
		var proc = new Process(cmd,args);
		var writing = new Lock();
		writing.release();
		inline function write(str:String):Bool
		{
			if (!writing.wait(timeout_secs / 2))
			{
				proc.kill();
				return false;
			} else {
				out.add(str);
				out.addChar('\n'.code);
				writing.release();
				return true;
			}
		}
		var threads = [];

		// spawn stdout/stderr handlers
		var waiting = new Deque();
		for (input in [proc.stdout, proc.stderr])
		{
			threads.push(Thread.create(function() {
				try
				{
					while(true)
					{
						var ln = input.readLine();
						if (!write(ln))
							break;
					}
				}
				catch(e:haxe.io.Eof) {}
				waiting.push(true);
			}));
		}

		var cur = Date.now().getTime(),
				ended = new Lock();
		// spawn waiting thread
		var ret = new Deque();
		threads.push(Thread.create(function() {
			for (i in 0...2)
				waiting.pop(true); // wait until process finishes
			ret.add(proc.exitCode());
			ended.release();
		}));

		var localOut = new StringBuf();
		if (!ended.wait(timeout_secs))
		{
			try { proc.kill(); } catch(e:Dynamic) {}
			try { proc.stdout.close(); } catch(e:Dynamic) {}
			try { proc.stderr.close(); } catch(e:Dynamic) {}
			try { proc.close(); } catch(e:Dynamic) {}

			write('\nKilled command $cmd ($args) : Process timed out (${ Std.int( (Date.now().getTime() - cur) / 1000 ) } secs)');
			return { out:out.toString(), exit: (1 << 20) + 1 }; //special return code for that
		}

		var id = ret.pop(false);
		if (id == null)
		{
			write('Assertation - id == null');
		}
		try { proc.stdout.close(); } catch(e:Dynamic) {}
		try { proc.stderr.close(); } catch(e:Dynamic) {}
		try { proc.close(); } catch(e:Dynamic) {}

		return { out:out.toString(), exit: id };
	}
}

/**
	iOs test runner server. Listens for connections and executes the application
**/
class ServerCmd extends mcli.CommandLine
{
	/**
		Sets the shared secret between peers
		@alias s
	**/
	public var secret:String = "notasecret";

	/**
		Sets the host to listen for connections
		@alias h
	**/
	public var host:String = "0.0.0.0";

	/**
		Sets the maximum number of connections to wait. Defaults to 5
		@alias m
	**/
	public var maxConnections:Int = 5;

	/**
		Sets the number of seconds to wait until a timeout is issued. Defaults to (5 * 60) seconds
	**/
	public var timeout:Float = 5 * 60;

	/**
		Sets the temp directory where the files will be stored
	**/
	public var tmpDir:String = "/tmp/";

	/**
		Sets the log dir
	**/
	public var logDir:String = "/var/log/ios-runner/";

	/**
		Show this message.
	**/
	public function help()
	{
		Sys.println(this.showUsage());
		Sys.exit(0);
	}

	/**
		Listens for connections at <port>
	**/
	public function listen(port:Int)
	{
		if (port == 0)
			throw 'You must enter a port';

		Server.listen(this, port);
	}
}
