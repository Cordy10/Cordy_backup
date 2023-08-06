﻿-- On OSX You can get everything up and running easily.
-- 1. brew install lua
-- 2. brew install luarocks
-- 3. luarocks install luafilesystem

require 'lfs'

-- Methods


function Trim(str)
	return (str:gsub("^%s*(.-)%s*$", "%1"))
end


function TableSize(T)
	local count = 0;
	for _ in pairs(T) do count = count + 1; end
	return count;
end


function AddSamplers() 

end


function ExtractConstantBuffers(text)
	local callback = function(match)
		table.insert(ConstantBuffers, match);
		return "";
	end

	if ( text:find("CONSTANT_BUFFER") )  then
		text = text:gsub("CONSTANT_BUFFER", "ConstantBuffer");		-- Replace CONSTANT_BUFFER with ConstantBuffer
		text = text:gsub("(ConstantBuffer(.-){(.-)});?", callback);	-- Extract definition
	end

	text = Trim(text);
	return text;
end


function DeclareShared(text)
	text = ExtractConstantBuffers(text);

	-- Then dump the remainder as "code"
	if #text > 0 then
		table.insert(Code, text); 
	end
end


function DeclareVertex(text)
	text = text:gsub("struct", "VertexStruct");
	text = text:gsub("COLOR;", "PDX_COLOR;");

	if ( text:find("OUTPUT") ) then
		text = text:gsub("POSITION", "PDX_POSITION");
	end

	table.insert(VertexStructs, text);
end


function DeclareShader(name, text)
	Shaders[name] = text;
end


function QuoteIfString(value)
	if ( type(value) == "string" ) then 
		return "\"" .. value .. "\"";
	end

	return value;
end

function Split(str, delim)
	if delim == nil then
		delim = "%s"
	end

	local result = {}

	for match in string.gmatch(str, "([^"..delim.."]+)") do
		table.insert(result, match)
	end

	return result;
end

function Indent(str, tabCount)
	local lines = Split(str, "\n");
	local outLines = {}
	local tabs = string.rep("\t", tabCount)

	for _,line in ipairs(lines) do
		table.insert(outLines, tabs .. line);
	end

	return table.concat(outLines, "\n");
end

function AsScriptValue(value)
	if ( type(value) == "boolean" ) then 
		if ( value ) then
			return "yes";
		else 
			return "no"; 
		end
	end

	return QuoteIfString(value);
end


function TableContains(t, value)
	for _,v in pairs(t) do
		if ( v == value ) then
			return true;
		end
	end

	return false;
end


function GenerateScriptCode(prefix, name, kvPairs, validKeys)
	local code = prefix .. " " .. name .. "\n" .. "{" .. "\n";

	for k,v in pairs(kvPairs) do
		if ( (validKeys == nil) or TableContains(validKeys, k) ) then
			code = code .. "\t" .. k .. " = " .. AsScriptValue(v) .. "\n";
		end
	end

	code = code .. "}";
	return code;
end


function ProcessShaderFile(inPath, outPath)
	if ( inPath == nil or outPath == nil ) then
		print("ProcessShaderFile requires an inPath and an outPath");
		return
	end

	print("ProcessShaderFile: " .. inPath);
	local usedEnvVars = {}
	local output = {}

	-- Clear State from last run

	-- Expected in child scripts
	Includes = {}
	Samplers = {}
	Defines = {}

	-- Generated by us
	ConstantBuffers = {}
	Code = {}
	VertexStructs = {}
	Shaders = {}
	BlendStates = {}	
	RasterizerStates = {}
	DepthStencilStates = {}
	PixelShaders = {}
	VertexShaders = {}
	Effects = {}

	-- Store a list of all used environment variables

	for k,v in pairs(_G) do
		usedEnvVars[k] = true;
	end	

	-- Process the file

	dofile(inPath);

	-- Iterate over each Shader and extract constant buffers

	for k,v in pairs(Shaders) do
		Shaders[k] = ExtractConstantBuffers(v);
	end

	-- Find new environment variables as "effects"

	for k,v in pairs(_G) do
		if ( (usedEnvVars[k] == nil) and (type(v) == "table") ) then
			if ( v.VertexShader ~= nil ) then
				Effects[k] = v;
			elseif ( v.BlendEnable ~= nil or v.SourceBlend ~= nil ) then			
				BlendStates[k] = v;
			elseif ( v.FillMode ~= nil ) then
				RasterizerStates[k] = v;
			elseif ( v.DepthEnable ~= nil or v.StencilEnable ~= nil or v.DepthWriteMask ~= nil ) then
				DepthStencilStates[k] = v;
			else
				print("[Warning] Unhandled Thing: " .. k);
			end
		end
	end	

	-- For each effect, build a list of Vertex and Pixel shaders

	for _,effect in pairs(Effects) do
		if ( Shaders[effect.VertexShader] ) then
			VertexShaders[effect.VertexShader] = Shaders[effect.VertexShader];
		end

		if ( Shaders[effect.PixelShader] ) then
			PixelShaders[effect.PixelShader] = Shaders[effect.PixelShader];
		end

		-- Map Old Keys to New Keys
		if ( effect["DepthStencil"] ) then 
			effect["DepthStencilState"] = effect["DepthStencil"];
			effect["DepthStencil"] = nil;
		end

		-- Deprecated Tags
		if ( effect["ShaderModel"] ) then effect["ShaderModel"] = nil; end

	end

	-- Includes

	for i,v in ipairs(Includes) do Includes[i] = "\t" .. QuoteIfString(v); end
	local includes = "Includes = {\n" .. table.concat(Includes, "\n") .. "\n}\n";
	table.insert(output, "## Includes")
	table.insert(output, includes); 

	-- Samplers

	local validSamplerKeys = {"Index", "MinFilter", "MagFilter", "MipFilter", "AddressU", "AddressV", "MipMapLodBias", "Type"};
	local samplerCode = "PixelShader = \n{\n\tSamplers = \n\t{\n";
	local nextIndex = 0;
	local samplersDone = 0;
	local samplerCount = TableSize(Samplers);

	while (samplersDone < samplerCount) do
		for name,sampler in pairs(Samplers) do 
			if ( sampler.Index == nextIndex ) then
				samplerCode = samplerCode .. "\t\t" .. name .. " = \n\t\t{\n";  

				for k,v in pairs(sampler) do 
					if ( TableContains(validSamplerKeys, k) ) then
						samplerCode = samplerCode .. "\t\t\t" .. k .. " = " .. QuoteIfString(v) .. "\n"; 
					end
				end
				
				samplerCode = samplerCode .. "\t\t}\n\n";	
				samplersDone = samplersDone + 1;
			end	
		end

		nextIndex = nextIndex + 1;

		if nextIndex == 64 then 
			print("Failed to find all samplers - is one missing an index?");
			samplersDone = samplerCount;
		end		
	end

	samplerCode = samplerCode .. "\n\t}\n}\n";
	table.insert(output, "## Samplers");
	table.insert(output, samplerCode);	

	-- Vertex Structs

	local vertStructs = table.concat(VertexStructs, "\n\n");
	table.insert(output, "## Vertex Structs")
	table.insert(output, vertStructs);

	-- Constant Buffers

	local constBuffers = table.concat(ConstantBuffers, "\n\n");
	table.insert(output, "## Constant Buffers");
	table.insert(output, constBuffers);

	-- Shared Code

	table.insert(output, "## Shared Code");

	for _,v in ipairs(Code) do
		local codeBlock = "Code" .. "\n" .. "[[" .. "\n";
		codeBlock = codeBlock .. v;
		codeBlock = codeBlock .. "\n" .. "]]" .. "\n";

		table.insert(output, codeBlock);
	end

	-- Vertex Shaders

	local shaderCode = "VertexShader = " .. "\n" .. "{" .. "\n";
	for name, shader in pairs(VertexShaders) do
		shader = Indent(shader, 2);

		shaderCode = shaderCode .. "\t" .. "MainCode " .. name .. "\n" .. "\t" .. "[[" .. "\n";
		shaderCode = shaderCode .. shader;
		shaderCode = shaderCode .. "\n" .. "\t" .. "]]" .. "\n\n";		
	end
	shaderCode = shaderCode .. "}\n";
	table.insert(output, "## Vertex Shaders");
	table.insert(output, shaderCode);

	-- Pixel Shaders

	local shaderCode = "PixelShader = " .. "\n" .. "{" .. "\n";
	for name, shader in pairs(PixelShaders) do
		-- Need to gsub old main def with main (...) : COLOR to main (...) : PDX_COLOR
		shader = shader:gsub(" : COLOR", " : PDX_COLOR")

		shader = Indent(shader, 2);
		shaderCode = shaderCode .. "\t" .. "MainCode " .. name .. "\n" .. "\t" .. "[[" .. "\n";
		shaderCode = shaderCode .. shader;
		shaderCode = shaderCode .. "\n" .. "\t" .. "]]" .. "\n\n";		
	end
	shaderCode = shaderCode .. "}\n";
	table.insert(output, "## Pixel Shaders");
	table.insert(output, shaderCode);

	-- Blend States

	local validBlendKeys = {"BlendEnable", "AlphaTest", "SourceBlend", "DestBlend", "BlendOp", "SourceAlpha", "DestAlpha", "BlendOpAlpha", "WriteMask"};
	table.insert(output, "## Blend States");

	for name,state in pairs(BlendStates) do
		table.insert(output, GenerateScriptCode("BlendState", name, state, validBlendKeys));
	end

	-- Rasterizer States

	table.insert(output, "## Rasterizer States");

	for name,state in pairs(RasterizerStates) do
		table.insert(output, GenerateScriptCode("RasterizerState", name, state));
	end	

	-- Depth Stencil States

	table.insert(output, "## Depth Stencil States");

	for name,state in pairs(DepthStencilStates) do
		table.insert(output, GenerateScriptCode("DepthStencilState", name, state));
	end		

	-- Effects

	table.insert(output, "## Effects");

	for name,effect in pairs(Effects) do
		table.insert(output, GenerateScriptCode("Effect", name, effect));	
	end


	-- Clear environment variables that weren't set before

	for k,v in pairs(_G) do
		if ( usedEnvVars[k] == nil ) then
			_G[k] = nil;
		end
	end

	-- Write the file!
	local contents = table.concat(output, "\n\n");

	local file = io.open(outPath, "w");
	file:write(contents);
	file:close();
end


function ProcessFxhFile(inPath, outPath)
	if ( inPath == nil or outPath == nil ) then
		print("ProcessFxhFile requires an inPath and an outPath");
		return
	end

	print("ProcessFxhFile: " .. inPath);	
	local output = {}

	ConstantBuffers = {}
	Code = {}

	local inFile = io.open(inPath, "r");
	local contents = inFile:read("*all");
	inFile:close();

	DeclareShared(contents);

	-- Constant Buffers

	local constBuffers = table.concat(ConstantBuffers, "\n\n");
	table.insert(output, "## Constant Buffers");
	table.insert(output, constBuffers);

	-- Shared Code

	table.insert(output, "## Shared Code");

	for _,v in ipairs(Code) do
		local codeBlock = "Code" .. "\n" .. "[[" .. "\n";
		codeBlock = codeBlock .. v;
		codeBlock = codeBlock .. "\n" .. "]]" .. "\n";

		table.insert(output, codeBlock);
	end	

	contents = table.concat(output, "\n\n");

	local file = io.open(outPath, "w");
	file:write(contents);
	file:close();
end



function Main()
	local inDir = "OldFX";
	local outDir = "FX";

	for file in lfs.dir(inDir) do
		if ( (file:lower():sub(-4) == ".lua") and (file:lower():sub(1, 13) ~= "shaderfactory") ) then
			local inPath = inDir .. "/" .. file;
			local outPath = outDir .. "/" .. file:gsub(".lua", ".shader");
			ProcessShaderFile(inPath, outPath);
		end

		if ( (file:lower():sub(-4) == ".fxh") ) then
			local inPath = inDir .. "/" .. file;
			local outPath = outDir .. "/" .. file;
			ProcessFxhFile(inPath, outPath);
		end
	end
end


Main();



--[[
for file in lfs.dir("C:\Program Files") do
    if lfs.attributes(file,"mode") == "file" then print("found file, "..file)
    elseif lfs.attributes(file,"mode")== "directory" then print("found dir, "..file," containing:")
        for l in lfs.dir("C:\\Program Files\\"..file) do
             print("",l)
        end
    end
end
]]---

