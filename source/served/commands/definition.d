module served.commands.definition;

import served.extension;
import served.types;
import served.utils.ddoc;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.coms;

import std.experimental.logger;
import std.path : buildPath, isAbsolute;
import std.string;
import std.algorithm : any;

import fs = std.file;
import io = std.stdio;

struct DeclarationInfo
{
	string declaration;
	Location location;
}

DeclarationInfo findDeclarationImpl(WorkspaceD.Instance instance, scope ref Document doc,
	int bytes, bool includeDefinition)
{
	auto result = instance.get!DCDComponent.findDeclaration(doc.rawText, bytes).getYield;
	if (result == DCDDeclaration.init)
		return DeclarationInfo.init;

	auto uri = doc.uri;
	if (result.file != "stdin")
	{
		if (isAbsolute(result.file))
			uri = uriFromFile(result.file);
		else
			uri = null;
	}

	trace("raw declaration result: ", uri, ":", result.position);

	size_t byteOffset = cast(size_t) result.position;
	bool tempLoad;
	auto found = documents.getOrFromFilesystem(uri, tempLoad);
	DeclarationInfo ret;
	if (found.uri)
	{
		TextRange range;
		if (instance.has!DCDExtComponent)
		{
			auto dcdext = instance.get!DCDExtComponent;
			range = getDeclarationRange(dcdext, found, byteOffset, includeDefinition);

			trace("  declaration refined to ", range);
		}
		if (range is TextRange.init)
		{
			auto pos = found.bytesToPosition(byteOffset);
			range = TextRange(pos, pos);
		}
		if (range !is TextRange.init)
		{
			ret.declaration = found.sliceRawText(range).idup;

			// TODO: resolve auto type

			if (instance.has!DfmtComponent)
			{
				trace("Formatting declaration ", [ret.declaration]);

				ret.declaration = instance.get!DfmtComponent.formatSync(ret.declaration,
					[
						"--keep_line_breaks=false",
						"--single_indent=true",
						"--indent_size=2",
						"--indent_style=space",
						"--max_line_length=60",
						"--soft_max_line_length=50",
						"--end_of_line=lf"
					]);
			}
		}
		if (tempLoad)
			documents.unloadDocument(uri);
		ret.location = Location(uri, range);
	}

	return ret;
}

TextRange getDeclarationRange(DCDExtComponent dcdext, ref Document doc, size_t byteOffset, bool includeDefinition)
{
	auto range = dcdext.getDeclarationRange(doc.rawText, byteOffset, includeDefinition);
	if (range == typeof(range).init)
		return TextRange.init;
	return doc.byteRangeToTextRange(range);
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto instance = activeInstance = backend.getBestInstance!DCDComponent(
			params.textDocument.uri.uriToFile);
	if (!instance)
		return ArrayOrSingle!Location.init;

	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return ArrayOrSingle!Location.init;

	auto result = findDeclarationImpl(instance, document,
			cast(int) document.positionToBytes(params.position), true);
	if (result == DeclarationInfo.init)
		return ArrayOrSingle!Location.init;

	return ArrayOrSingle!Location(result.location);
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto instance = activeInstance = backend.getBestInstance!DCDComponent(
			params.textDocument.uri.uriToFile);
	if (!instance)
		return Hover.init;

	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return Hover.init;

	DCDComponent dcd = instance.get!DCDComponent();

	auto docs = dcd.getDocumentation(document.rawText,
			cast(int) document.positionToBytes(params.position)).getYield;
	auto marked = docs.ddocToMarked;

	try
	{
		auto result = findDeclarationImpl(instance, document,
				cast(int) document.positionToBytes(params.position), false);
		result.declaration = result.declaration.strip;
		if (result.declaration.length)
			marked = MarkedString(result.declaration, "d") ~ marked;
	}
	catch (Exception e)
	{
	}

	// Fallback: if no documentation and no declaration, try to get raw definition from DCD
	// Check if marked is empty or contains only empty strings
	bool hasContent = marked.length > 0 && marked.any!(m => m.value.strip.length > 0);
	if (!hasContent)
	{
		try
		{
			auto completions = dcd.listCompletion(document.rawText,
					cast(int) document.positionToBytes(params.position)).getYield;
			if (completions.type == DCDCompletions.Type.identifiers && completions.identifiers.length > 0)
			{
				// DCD returns identifiers at cursor position. Use the first one as it's the most relevant
				// (typically the symbol directly under the cursor)
				auto identifier = completions.identifiers[0];
				if (identifier.definition.length > 0)
				{
					marked = [MarkedString(identifier.definition, "d")];
					trace("Using fallback definition for hover: ", identifier.definition);
				}
			}
		}
		catch (Exception e)
		{
			trace("Failed to get fallback definition for hover: ", e.msg);
		}
	}

	Hover ret;
	ret.contents = marked;
	return ret;
}
