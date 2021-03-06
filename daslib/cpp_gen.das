options indenting = 4
options no_aot = true

module cpp_gen


require fio
require daslib/json
require daslib/json_boost
require daslib/strings_boost
require daslib/regex
require daslib/regex_boost

let verbose = false

/*
    config
*/

var local_type_names : array<string>

var blocked_type_names : array<string>

var blocked_functions : array<string> <-  [{string []
    "operator delete";
    "operator new";
    "__security_init_cookie";
    "__security_check_cookie"
}];

var cmres_functions : array<string>

var allow_extern_c = false

/*
    end of configuration
*/

enum ScopeKind
    Namespace
    Struct

struct Scope
    name : string
    kind : ScopeKind

enum AccessKind
    Private
    Public
    Protected

struct ClangAstDecl
    name    : string
    cppName : string

struct ClangTypedef : ClangAstDecl
    qtype   : string

struct ClangEnum : ClangAstDecl
    eclass  : bool
    etype   : string
    edecl   : array<string>

struct ClangGlobalVar : ClangAstDecl
    mangledName : string
    gtype       : string

struct ClangStructField : ClangAstDecl
    qtype       : string
    access      : AccessKind
    isBitfield  : bool

struct ClangFuncArg : ClangAstDecl
    atype   : string
    value   : string
    vtype   : string

struct ClangFunc : ClangAstDecl
    mangledName : string
    ftype       : string
    isMethod    : bool
    ofClass     : string
    args        : array<ClangFuncArg>

struct ClangStruct : ClangAstDecl
    tag     : string
    fields  : array<ClangStructField>
    methods : array<ClangFunc>

struct ClangAst
    typedefs : table<string;ClangTypedef>
    enums : table<string;ClangEnum>
    structs : table<string;ClangStruct>
    funcs : table<string;ClangFunc>
    globals : table<string;ClangGlobalVar>

var name_stack : array<Scope>
var access_stack : array<AccessKind>
var struct_stack : array<string>
var ast : ClangAst

def is_str(jso,str)
    return (jso is _string) && ((jso as _string)==str)

def with_object(var jso; field; blk:block<(var val:table<string; JsonValue?>):void> )
    assert(jso[field] is _object)
    invoke(blk, jso[field] as _object)

def with_array(var jso; field; blk:block<(var val:array<JsonValue?>):void> )
    assert(jso[field] is _array)
    invoke(blk, jso[field] as _array)

def is_valid_loc(var loc)
    if loc |> length == 0
        return false
    return true

def onInner(var root)
    root |> with_array("inner") <| $(inner)
        for idecl in inner
            assert(idecl is _object)
            var decl & = idecl as _object
            var skip = false
            if decl |> key_exists("loc")
                decl |> with_object("loc") <| $ ( loc )
                    skip = ! loc |> is_valid_loc
            if skip
                if verbose
                    print("// skipping {decl["name"] as _string}\n")
                continue
            let kind = decl["kind"] as _string
            if kind=="CXXRecordDecl"
                onStruct(decl)
            elif kind=="NamespaceDecl"
                onNamespace(decl)
            elif kind=="FieldDecl"
                onField(decl)
            elif kind=="FunctionDecl"
                onFunction(decl)
            elif kind=="CXXMethodDecl"
                onMethod(decl)
            elif kind=="EnumDecl"
                onEnum(decl)
            elif kind=="VarDecl"
                onVar(decl)
            elif kind=="TypedefDecl"
                onTypeDecl(decl)
            elif kind=="AccessSpecDecl"
                onAccess(decl)
            elif kind=="LinkageSpecDecl"
                onLinkageSpec(decl)
            else
                print("warning: unsupported {kind}\n")


[sideeffects] // TODO: fixme. find why we need to specify [sideeffects] here
def onLinkageSpec(var root)
    if !allow_extern_c
        return
    if ! root |> key_exists("inner")
        return
    if verbose
        if root |> key_exists("language")
            print("extern \"{root["language"] as _string}\"\n")
    onInner(root)

def onNamespace(var root)
    if ! root |> key_exists("inner")
        return
    let name = root["name"] as _string
    let fullName = join([[for n in name_stack; n.name]],"::") + "::" + name
    if verbose
        print("namespace {name} //{fullName}\n")
    name_stack |> push([[Scope name=name, kind=ScopeKind Namespace]])
    onInner(root)
    name_stack |> pop()

def onEnum(var root)
    let name = root["name"] as _string
    let fullName = getCppName(name)
    if root |> key_exists("scopedEnumTag")
        let tag = root["scopedEnumTag"] as _string
        let qtype = getQualType(root,"fixedUnderlyingType")
        if verbose
            print("enum {tag} {name} : {qtype} // {fullName}\n")
        ast.enums[fullName] <- [[ClangEnum
            name=name,
            cppName=fullName,
            eclass=true,
            etype=qtype
        ]]
    else
        if verbose
            print("enum {name} // {fullName}\n")
        ast.enums[fullName] <- [[ClangEnum
            name=name,
            cppName=fullName,
            eclass=false
        ]]
    root |> with_array("inner") <| $ ( inner )
        for edo in inner
            assert(edo is _object)
            var ed & = edo as _object
            if ed["kind"] as _string == "EnumConstantDecl"
                var cname = ed["name"] as _string
                ast.enums[fullName].edecl |> push(cname)

def onVar(var root)
    let name = root["name"] as _string
    let fullName = getCppName(name)
    let mangledName = root["mangledName"] as _string // todo: undecorate mangled name
    var qualType = getQualType(root)
    if verbose
        print("global variable {name} // {fullName}\n// {mangledName}\n// {qualType}\n")
    ast.globals[fullName] <- [[ClangGlobalVar
        name = name,
        cppName = fullName,
        mangledName = mangledName,
        gtype = qualType
    ]]

def getQualType(var root; field:string="type")
    var qto & = root[field] as _object
    return qto["qualType"] as _string

def onNumericLiteral(var inner_obj)
    var value = ""
    var valueType =""
    let valueCategory = inner_obj["valueCategory"] as _string
    if valueCategory=="rvalue"
        value = inner_obj["value"] as _string
    valueType = getQualType(inner_obj)
    return [[auto value, valueType]]

def onInitArg(var root)
    var value = ""
    var valueType = ""
    if root |> key_exists("inner")
        root |> with_array("inner") <| $ ( inner )
            var inner_obj & = inner[0] as _object
            let kind = inner_obj["kind"] as _string
            if kind=="ImplicitCastExpr"
                let castKind = inner_obj["castKind"] as _string
                if castKind=="NullToPointer"
                    value = "nullptr"
                elif castKind=="ArrayToPointerDecay"
                    let valueCategory = inner_obj["valueCategory"] as _string
                    valueType = getQualType(inner_obj)
                    if valueCategory=="rvalue"
                        if valueType=="const char *"
                            inner_obj |> with_array("inner") <| $ ( iarr )
                                var iobj & = iarr[0] as _object
                                value = iobj["value"] as _string
                        else
                            print("warning: unsupported decay type {valueType}")
                else
                    print("warning: unsupproted cast kind {castKind}\n")
            elif kind=="IntegerLiteral" || kind=="FloatingLiteral"
                let literal = onNumericLiteral(inner_obj)
                value = literal._0
                valueType = literal._1
            elif kind=="UnaryOperator"
                let opCode = inner_obj["opcode"] as _string
                inner_obj |> with_array("inner") <| $ (iinner)
                    var iinner_obj & = iinner[0] as _object
                    let ikind = iinner_obj["kind"] as _string
                    if ikind=="IntegerLiteral" || ikind=="FloatingLiteral"
                        let literal = onNumericLiteral(iinner_obj)
                        value = opCode + literal._0
                        valueType = literal._1
            elif kind=="CXXBoolLiteralExpr"
                let valueCategory = inner_obj["valueCategory"] as _string
                if valueCategory=="rvalue"
                    value = (inner_obj["value"] as _bool) ? "true" : "false"
                valueType = getQualType(inner_obj)
            else
                print("warning: unsupproted init kind {kind}\n")
    return [[auto value, valueType]]

def onFunctionBody(var root) : ClangFunc
    let name = root["name"] as _string
    let fullName = getCppName(name)
    let mangledName = root["mangledName"] as _string // todo: undecorate mangled name
    var qualType = getQualType(root)
    if verbose
        print("function {name} // {fullName}\n// {mangledName}\n// {qualType}\n")
    var ffunc <- [[ClangFunc
        name=name,
        cppName=fullName,
        mangledName=mangledName,
        ftype=qualType,
        isMethod=false
    ]]
    if root |> key_exists("inner")
        root |> with_array("inner") <| $ ( inner )
            for fad in inner
                assert(fad is _object)
                var ad & = fad as _object
                if ad["kind"] as _string == "ParmVarDecl"
                    let fieldName = key_exists(ad,"name") ? (ad["name"] as _string) : ""
                    var fqualType = getQualType(ad)
                    var fieldInit = ""
                    var fieldInitType = ""
                    if key_exists(ad,"init")
                        let arg = onInitArg(ad)
                        fieldInit  = arg._0
                        fieldInitType = arg._1
                    ffunc.args |> emplace([[ClangFuncArg
                        name=fieldName,
                        atype=fqualType,
                        value=fieldInit,
                        vtype=fieldInitType
                    ]])
                    if verbose
                        print("\t{fqualType} {fieldName} = {fieldInit}\n")
    return <- ffunc

def onMethod(var root)
    var in_class = struct_stack[length(struct_stack)-1]
    ast.structs[in_class].methods |> emplace <| onFunctionBody(root)

def onFunction(var root)
    var fdecl <- onFunctionBody(root)
    ast.funcs[fdecl.mangledName] <- fdecl

def onStruct(var root)
    let name = key_exists(root,"name") ? (root["name"] as _string) : ""
    let tagUsed = root["tagUsed"] as _string
    let fullName = getCppName(name)
    if verbose
        print("{tagUsed} {name} // {fullName}\n")
    if ! root |> key_exists("inner")
        return
    if tagUsed=="struct"
        access_stack |> push(AccessKind Public)
    else
        access_stack |> push(AccessKind Private)
    ast.structs[fullName] <- [[ClangStruct
        name=name,
        cppName=fullName,
        tag=tagUsed
    ]]
    name_stack |> push([[Scope name=name, kind=ScopeKind Struct]])
    struct_stack |> push(fullName)
    onInner(root)
    struct_stack |> pop()
    name_stack |> pop()
    access_stack |> pop()

def onAccess(var root)
    let access = root["access"] as _string
    var kind = AccessKind Public
    if access=="public"
        kind = AccessKind Public
    elif access=="private"
        kind = AccessKind Private
    elif access=="protected"
        kind = AccessKind Protected
    else
        panic("unsupported access kind {access}\n")
    access_stack[length(access_stack)-1] = kind

def isBitfield(var root)
    if root |> key_exists("isBitfield")
        if root["isBitfield"] as _bool
            return true
    return false

def onField(var root)
    let name = key_exists(root,"name") ? (root["name"] as _string) : ""
    var qualType = getQualType(root)
    var access = access_stack[length(access_stack)-1]
    if verbose
        print("\t{qualType} {name} // {access}\n")
    let sfn = struct_stack[length(struct_stack)-1]
    ast.structs[sfn].fields |> push([[ClangStructField
        name = name,
        cppName = name,
        qtype = qualType,
        access = access,
        isBitfield = root |> isBitfield
    ]])

def getCppName(baseName)
    var name = join([[for n in name_stack; n.name]],"::")
    if length(name) != 0
        name = "{name}::{baseName}"
    else
        name = baseName
    return name

def onTypeDecl(var root)
    let name = root["name"] as _string
    let fullName = getCppName(name)
    var qualType = getQualType(root)
    if verbose
        print("typedecl {name} = {qualType} // {fullName}\n")
    ast.typedefs[fullName] = [[ClangTypedef
        name=name,
        cppName=fullName,
        qtype=qualType
    ]]

def isBlockedType(qtype:string)
    for btn in blocked_type_names
        if qtype |> find(btn) != -1
            return true
    return false

def isLocalType(qtype:string)
    for btn in local_type_names
        if qtype |> find(btn) != -1
            return true
    return false


def genEnums(hf,mf,df:FILE const?)
    fprint(hf,"// ------------\n// enumerations\n// ------------\n\n")
    fprint(mf,"// ------------\n// enumerations\n// ------------\n\n")
    fprint(df,"// ------------\n// enumerations\n// ------------\n\n")
    for en in values(ast.enums)
        fprint(df,"addEnumeration(make_smart<Enumeration{en.name}>());\n");
        if en.eclass
            fprint(hf,"BIND_ENUM_CAST({en.cppName})\n")
            fprint(mf,"DAS_BASE_BIND_ENUM({en.cppName},{en.name}\n")
        else
            fprint(hf,"DAS_BIND_ENUM_CAST_98({en.cppName})\n")
            fprint(mf,"DAS_BASE_BIND_ENUM_98({en.cppName},{en.name}\n")
        for ene in en.edecl
            fprint(mf,"\t,{ene}\n")
        fprint(mf,")\n\n")
    fprint(hf,"\n")
    fprint(df,"\n")

def needToGenStruct(st)
    if empty(st.name)
        return false
    // TODO: skip unrelated
    return true

def needToGenField(fld)
    if empty(fld.name)
        return false
    if fld.access != AccessKind Public
        return false
    if fld.qtype |> isBlockedType
        return false
    return true

def genStructs(hf,mf,df:FILE const?)
    fprint(hf,"// ------------\n// structures\n// ------------\n\n")
    fprint(mf,"// ------------\n// structures\n// ------------\n\n")
    fprint(df,"// ------------\n// structures\n// ------------\n\n")
    for st in values(ast.structs)
        if !needToGenStruct(st)
            continue
        fprint(mf,"\tIMPLEMENT_EXTERNAL_TYPE_FACTORY({st.name},{st.cppName})\n")
    fprint(mf,"\n")
    for st in values(ast.structs)
        if !needToGenStruct(st)
            continue
        fprint(df,"auto ann_{st.name} = make_smart<{st.name}_GeneratedAnnotation>(lib);\n")
        fprint(df,"addAnnotation(ann_{st.name});\n")
        fprint(hf,"MAKE_EXTERNAL_TYPE_FACTORY({st.name},{st.cppName})\n")
        fprint(mf,"struct {st.name}_GeneratedAnnotation : ManagedStructureAnnotation<{st.cppName}> \{\n")
        if isLocalType(st.name)
            fprint(mf,"\tvirtual bool isLocal() const override \{ return true; \}\n")
        fprint(mf,"\t{st.name}_GeneratedAnnotation(ModuleLibrary & ml) : ManagedStructureAnnotation (\"{st.name}\", ml) \{\n")
        fprint(mf,"\t\}\n")
        fprint(mf,"\tvoid init () \{\n")
        for fld in st.fields
            if !needToGenField(fld)
                continue
            if fld.isBitfield           // TODO: support bitfields
                continue
            fprint(mf,"\t\taddField<DAS_BIND_MANAGED_FIELD({fld.cppName})>(\"{fld.name}\",\"{fld.cppName}\");\n")
        fprint(mf,"\t\}\n\};\n")
    for st in values(ast.structs)
        if !needToGenStruct(st)
            continue
        fprint(df,"initRecAnnotation(ann_{st.name},lib);\n")
    fprint(hf,"\n")
    fprint(df,"\n")

def isBlockedFun(fn)
    if fn.ftype |> find("...") != -1
        print("warning: variadic function {fn.name} aka {fn.cppName}\n")
        return true
    for fa in fn.args
        if fa.atype |> isBlockedType
            return true
    for bf in blocked_functions
        if bf == fn.cppName
            return true
    return false

def qType2FnType(st)
    let ob = find(st,"(")
    assert(ob!=-1)
    return slice(st,0,ob) + "(*)" + slice(st,ob)

def isRefFun(fn)
    let ob = find(fn.ftype,"(")
    assert(ob!=-1)
    var cppResType = slice(fn.ftype,0,ob)
    if cppResType |> starts_with("const ")
        cppResType = slice(cppResType, 6)
    if cppResType |> ends_with(" ")
        cppResType = slice(cppResType, 0, -1)
    if cppResType |> ends_with("&")
        return true
    return false

def isCmresFun(fn)
    // note: hacking cpp type to autodetect CMRES
    let ob = find(fn.ftype,"(")
    assert(ob!=-1)
    var cppResType = slice(fn.ftype,0,ob)
    if cppResType |> starts_with("const ")
        cppResType = slice(cppResType, 6)
    if cppResType |> ends_with(" ")
        cppResType = slice(cppResType, 0, -1)
    if ast.structs |> key_exists(cppResType)
        return true
    for bf in cmres_functions
        if bf == fn.cppName
            return true
    return false

def getFunctions(hf,mf,df:FILE const?)
    fprint(df,"// ------------\n// functions\n// ------------\n\n")
    var all_fn : table<string; int>
    for fn in values(ast.funcs)
        all_fn[fn.cppName] ++
    for fn in values(ast.funcs)
        if fn.isMethod
            continue
        if fn |> isBlockedFun
            continue
        var bind_enchantation = ""
        if all_fn[fn.cppName] > 1
            let fType = qType2FnType(fn.ftype)
            bind_enchantation = "{fType},{fn.cppName}"
            print("warning: {fn.cppName} using clang-ast binding of {fType}\n")
        else
            bind_enchantation = "DAS_BIND_FUN({fn.cppName})"
        var extra_enchantation = ""
        if fn |> isRefFun
            extra_enchantation = ", SimNode_ExtFuncCallRef"
        elif fn |> isCmresFun
            extra_enchantation = ", SimNode_ExtFuncCallAndCopyOrMove"
        fprint(df,"addExtern<{bind_enchantation}{extra_enchantation}>(*this, lib, \"{fn.name}\",SideEffects::worstDefault, \"{fn.cppName}\")\n")
        fprint(df,"\t->args(\{")
        for arg,argi in fn.args,range(100500)
            if argi!=0
                fprint(df,",")
            if empty(arg.name)
                fprint(df,"\"arg{argi}\"")
            else
                fprint(df,"\"{arg.name}\"")
        fprint(df,"\})\n")
        for arg,argi in fn.args,range(100500)
            if !empty(arg.value)
                if arg.value=="nullptr"
                    if arg.atype=="const char *"
                        fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstString>(\"\"))\n")
                    else
                        fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstPtr>())\n")
                elif arg.vtype=="int"
                    fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstInt>({arg.value}))\n")
                elif arg.vtype=="float"
                    fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstFloat>({arg.value}))\n")
                elif arg.vtype=="bool"
                    fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstBool>({arg.value}))\n")
                elif arg.vtype=="const char *"
                    fprint(df,"\t\t->arg_init({argi},make_smart<ExprConstString>({arg.value}))\n")
                else
                    fprint(df,"\t\t// {arg.name} : {arg.atype} = {arg.value}\n")
                    print("warning: unsupported init {arg.atype} of {arg.vtype}\n")
        fprint(df,";\n")

def genBindings(hf,mf,df:FILE const?)
    genEnums(hf,mf,df)
    genStructs(hf,mf,df)
    getFunctions(hf,mf,df)

def bindHeaders ( fname, outprefix:string )
    fopen(fname, "r") <| $ ( f )
        if f==null
            print("can't open {fname}")
        else
            fmap(f) <| $ ( data )
                print ( "\n{fname}\n" )
                var error = ""
                var json = read_json(data, error)
                if json == null
                    panic("failed to parse, {error}\n")
                else
                    assert(json is _object)
                    var root & = json as _object
                    verify( root["kind"] |> is_str <| "TranslationUnitDecl" )
                    onInner(root)
                    // debug(ast,"AST =")
                    fopen("{outprefix}.h","wb") <| $(hf)
                        fwrite(hf,"#pragma once\n\n")
                        fopen("{outprefix}.cpp_inc","wb") <| $(mf)
                            fopen("{outprefix}.inc","wb") <| $(df)
                                genBindings(hf,mf,df)


def genDefineConstants(fname,prefix:string)
    var reg_def_hex <- %regex~#define\s+(\w+)\s+(0x[0-9A-Za-z]+)%%
    var reg_def_dec <- %regex~#define\s+(\w+)\s+(\d+)%%
    fopen(fname,"rb") <| $( f )
        if f == null
            panic("can't open {fname}")
        fopen("{prefix}.const_inc","wb") <| $(hf)
            if hf==null
                panic("can't write {prefix}.const_inc")
            var dict : table<string; int>
            var ofs : table<int; bool>
            let data = fread(f)
            regex_foreach(reg_def_hex,data) <| $ ( r )
                ofs[r.x] = true
                let DEF = regex_group(reg_def_hex,1,data)
                let VAL = regex_group(reg_def_hex,2,data)
                fprint(hf,"addConstant(*this,\"{DEF}\",uint32_t({VAL}));\n")
                return true
            regex_foreach(reg_def_dec,data) <| $ ( r )
                if ! ofs |> key_exists(r.x)
                    let DEF = regex_group(reg_def_dec,1,data)
                    let VAL = regex_group(reg_def_dec,2,data)
                    fprint(hf,"addConstant(*this,\"{DEF}\",int32_t({VAL}));\n")
                return true
