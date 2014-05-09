package unihx._internal.editor;
import haxe.ds.Vector;

using StringTools;

@:nativeGen @:keep class AssetProcessor extends unityeditor.AssetPostprocessor
{
	static function OnPostprocessAllAssets(
			importedAssets:Vector<String>,
			deletedAssets:Vector<String>,
			movedAssets:Vector<String>,
			movedFromAssetPaths:Vector<String>)
	{
		var sources = [];
		for (str in importedAssets)
		{
			if (str.endsWith(".hx"))
				sources.push(str);
		}
		for (str in movedAssets)
		{
			if (str.endsWith(".hx"))
				sources.push(str);
		}
		if (sources.length > 0)
		{
			trace(sources);
		}
	}
}
