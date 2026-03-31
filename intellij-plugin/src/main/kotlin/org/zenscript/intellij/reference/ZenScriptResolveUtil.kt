package org.zenscript.intellij.reference

import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.roots.ProjectRootManager
import com.intellij.openapi.vfs.VfsUtilCore
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.PsiManager
import com.intellij.psi.TokenType
import com.intellij.psi.util.PsiTreeUtil
import org.zenscript.intellij.ZenScriptFile
import org.zenscript.intellij.psi.ZenScriptElementTypes
import org.zenscript.intellij.psi.*
import org.zenscript.intellij.settings.ZenScriptPreludeService

data class ProjectSymbol(val element: ZenScriptNamedElement, val relativePath: String)

object ZenScriptResolveUtil {
    private val LOG = Logger.getInstance(ZenScriptResolveUtil::class.java)
    fun resolveInScope(from: PsiElement, name: String): PsiElement? {
        var current: PsiElement? = from.parent
        while (current != null) {
            // Search siblings above `from` in the current scope
            for (child in current.children) {
                // Only look at declarations that come before the reference in the same scope,
                // unless we're at file level (forward references allowed)
                if (child === from || PsiTreeUtil.isAncestor(child, from, false)) break
                if (child is ZenScriptNamedElement && child.name == name) {
                    return child
                }
            }

            // If we're at file level, also search declarations after the reference (forward refs)
            if (current === from.containingFile) {
                for (child in current.children) {
                    if (child is ZenScriptNamedElement && child.name == name) {
                        return child
                    }
                }
            }

            // Check function parameters (only direct children of PARAMETER_LIST)
            if (current is ZenScriptFnDeclaration) {
                val paramList = current.node.findChildByType(ZenScriptElementTypes.PARAMETER_LIST)
                if (paramList != null) {
                    for (paramNode in paramList.getChildren(null)) {
                        val param = paramNode.psi
                        if (param is ZenScriptParameter && param.name == name) {
                            return param
                        }
                    }
                }
            }

            current = current.parent
        }

        // Fallback: resolve via imports
        val imported = resolveViaImports(from.containingFile, name)
        if (imported != null) return imported

        // Final fallback: resolve via prelude
        return resolveViaPrelude(from.project, name)
    }

    fun collectVariants(from: PsiElement): List<String> {
        val result = LinkedHashSet<String>()
        var current: PsiElement? = from.parent
        while (current != null) {
            for (child in current.children) {
                if (child is ZenScriptNamedElement) {
                    child.name?.let { result.add(it) }
                }
            }
            // Check function parameters
            if (current is ZenScriptFnDeclaration) {
                val paramList = current.node.findChildByType(ZenScriptElementTypes.PARAMETER_LIST)
                if (paramList != null) {
                    for (paramNode in paramList.getChildren(null)) {
                        val param = paramNode.psi
                        if (param is ZenScriptParameter) {
                            param.name?.let { result.add(it) }
                        }
                    }
                }
            }
            current = current.parent
        }
        // Also collect imported symbol names
        val importedVariants = mutableListOf<String>()
        collectImportedVariants(from.containingFile, importedVariants)
        result.addAll(importedVariants)
        // Also collect prelude symbol names
        collectPreludeVariants(from.project, result)
        return result.toList()
    }

    fun resolveImportPath(context: PsiElement, path: String): ZenScriptFile? {
        val containingFile = context.containingFile?.virtualFile ?: return null
        val dir = containingFile.parent ?: return null
        val targetVFile = dir.findFileByRelativePath(path) ?: return null
        val psiFile = PsiManager.getInstance(context.project).findFile(targetVFile)
        return psiFile as? ZenScriptFile
    }

    fun findExportedSymbol(
        file: PsiFile,
        name: String,
        visited: MutableSet<PsiFile> = mutableSetOf()
    ): ZenScriptNamedElement? {
        if (!visited.add(file)) return null // cycle prevention

        // Search top-level named elements in the file
        for (child in file.children) {
            if (child is ZenScriptNamedElement && child.name == name) {
                return child
            }
        }

        // Check export-from statements for re-exports (transitive)
        for (child in file.children) {
            if (child is ZenScriptExportFromStatement) {
                for (symbol in child.getImportSymbols()) {
                    val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                    if (visibleName == name) {
                        val path = child.getPath() ?: continue
                        val originalName = symbol.getOriginalName() ?: continue
                        val targetFile = resolveImportPath(child, path) ?: continue
                        return findExportedSymbol(targetFile, originalName, visited)
                    }
                }
            }
        }

        return null
    }

    fun resolveViaImports(file: PsiFile?, name: String): PsiElement? {
        if (file == null) return null

        for (child in file.children) {
            when (child) {
                is ZenScriptImportStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        if (visibleName == name) {
                            val path = child.getPath() ?: continue
                            val originalName = symbol.getOriginalName() ?: continue
                            val targetFile = resolveImportPath(child, path) ?: continue
                            return findExportedSymbol(targetFile, originalName)
                        }
                    }
                }
                is ZenScriptUseStatement -> {
                    for (symbol in child.getVariantSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        if (visibleName == name) {
                            val enumName = child.getEnumName() ?: continue
                            val originalName = symbol.getOriginalName() ?: continue
                            val enumDecl = resolveInLocalScope(file, enumName)
                                ?: resolveImportOrExportFrom(file, enumName)
                                ?: resolveViaPrelude(file.project, enumName)
                            if (enumDecl is ZenScriptEnumDeclaration) {
                                val variant = findEnumVariant(enumDecl, originalName)
                                if (variant != null) return variant
                            }
                        }
                    }
                }
                is ZenScriptExportFromStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        if (visibleName == name) {
                            val path = child.getPath() ?: continue
                            val originalName = symbol.getOriginalName() ?: continue
                            val targetFile = resolveImportPath(child, path) ?: continue
                            return findExportedSymbol(targetFile, originalName)
                        }
                    }
                }
            }
        }
        return null
    }

    fun findEnumVariant(enumDecl: ZenScriptEnumDeclaration, variantName: String): ZenScriptEnumVariant? {
        for (child in enumDecl.children) {
            if (child is ZenScriptEnumVariant && child.name == variantName) {
                return child
            }
        }
        return null
    }

    private fun resolveInLocalScope(file: PsiFile, name: String): PsiElement? {
        for (child in file.children) {
            if (child is ZenScriptNamedElement && child.name == name) {
                return child
            }
        }
        return null
    }

    private fun resolveImportOrExportFrom(file: PsiFile, name: String): PsiElement? {
        for (child in file.children) {
            when (child) {
                is ZenScriptImportStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        if (visibleName == name) {
                            val path = child.getPath() ?: continue
                            val originalName = symbol.getOriginalName() ?: continue
                            val targetFile = resolveImportPath(child, path) ?: continue
                            return findExportedSymbol(targetFile, originalName)
                        }
                    }
                }
                is ZenScriptExportFromStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        if (visibleName == name) {
                            val path = child.getPath() ?: continue
                            val originalName = symbol.getOriginalName() ?: continue
                            val targetFile = resolveImportPath(child, path) ?: continue
                            return findExportedSymbol(targetFile, originalName)
                        }
                    }
                }
            }
        }
        return null
    }

    fun collectVariantElements(from: PsiElement): List<ZenScriptNamedElement> {
        val seen = LinkedHashSet<String>()
        val result = mutableListOf<ZenScriptNamedElement>()
        fun addUnique(element: ZenScriptNamedElement) {
            val name = element.name ?: return
            if (seen.add(name)) result.add(element)
        }

        var current: PsiElement? = from.parent
        while (current != null) {
            for (child in current.children) {
                if (child is ZenScriptNamedElement) {
                    addUnique(child)
                }
            }
            // Check function parameters
            if (current is ZenScriptFnDeclaration) {
                val paramList = current.node.findChildByType(ZenScriptElementTypes.PARAMETER_LIST)
                if (paramList != null) {
                    for (paramNode in paramList.getChildren(null)) {
                        val param = paramNode.psi
                        if (param is ZenScriptParameter) {
                            addUnique(param)
                        }
                    }
                }
            }
            current = current.parent
        }
        collectImportedVariantElements(from.containingFile, result, seen)
        collectPreludeVariantElements(from.project, result, seen)
        return result
    }

    fun collectImportedVariantElements(file: PsiFile?, result: MutableList<ZenScriptNamedElement>, seen: MutableSet<String> = mutableSetOf()) {
        if (file == null) return
        for (child in file.children) {
            when (child) {
                is ZenScriptImportStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val name = symbol.name ?: continue
                        if (seen.add(name)) result.add(symbol)
                    }
                }
                is ZenScriptUseStatement -> {
                    for (symbol in child.getVariantSymbols()) {
                        val name = symbol.name ?: continue
                        if (seen.add(name)) result.add(symbol)
                    }
                }
                is ZenScriptExportFromStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val name = symbol.name ?: continue
                        if (seen.add(name)) result.add(symbol)
                    }
                }
            }
        }
    }

    fun findStructField(structDecl: ZenScriptStructDeclaration, fieldName: String): ZenScriptStructField? {
        for (child in structDecl.children) {
            if (child is ZenScriptStructField && child.name == fieldName) {
                return child
            }
        }
        return null
    }

    /**
     * Resolves a field name in a struct literal (e.g. `x` in `Point { x: 3 }`).
     * Returns the [ZenScriptStructField] declaration, or null if not applicable.
     */
    fun resolveStructLiteralField(element: ZenScriptReferenceExpression): ZenScriptStructField? {
        // Check: is this REFERENCE_EXPRESSION followed by COLON?
        var next: PsiElement? = element.nextSibling
        while (next != null && next.node.elementType == TokenType.WHITE_SPACE) {
            next = next.nextSibling
        }
        if (next?.node?.elementType != ZenScriptTokenTypes.COLON) return null

        // Walk backwards from this element to find the LBRACE
        var prev: PsiElement? = element.prevSibling
        while (prev != null && prev.node.elementType != ZenScriptTokenTypes.LBRACE) {
            prev = prev.prevSibling
        }
        if (prev == null) return null // no LBRACE found

        // The REFERENCE_EXPRESSION before the LBRACE is the struct name
        var structNameRef: PsiElement? = prev.prevSibling
        while (structNameRef != null && structNameRef.node.elementType == TokenType.WHITE_SPACE) {
            structNameRef = structNameRef.prevSibling
        }
        if (structNameRef !is ZenScriptReferenceExpression) return null

        // Resolve the struct name to a declaration
        val structDecl = resolveInScope(structNameRef, structNameRef.getReferenceName() ?: return null)
        if (structDecl !is ZenScriptStructDeclaration) return null

        // Find the field in the struct
        val fieldName = element.getReferenceName() ?: return null
        return findStructField(structDecl, fieldName)
    }

    fun collectStructFields(structDecl: ZenScriptStructDeclaration): List<ZenScriptStructField> {
        return structDecl.children.filterIsInstance<ZenScriptStructField>()
    }

    fun collectEnumVariants(enumDecl: ZenScriptEnumDeclaration): List<ZenScriptEnumVariant> {
        return enumDecl.children.filterIsInstance<ZenScriptEnumVariant>()
    }

    private fun resolveViaPrelude(project: com.intellij.openapi.project.Project, name: String): PsiElement? {
        val preludeFile = project.getService(ZenScriptPreludeService::class.java)
            ?.getPreludeFile() ?: return null
        return findExportedSymbol(preludeFile, name)
    }

    private fun collectPreludeVariants(project: com.intellij.openapi.project.Project, result: MutableSet<String>) {
        val preludeFile = project.getService(ZenScriptPreludeService::class.java)
            ?.getPreludeFile() ?: return
        for (child in preludeFile.children) {
            if (child is ZenScriptNamedElement) {
                child.name?.let { result.add(it) }
            }
            if (child is ZenScriptExportFromStatement) {
                for (symbol in child.getImportSymbols()) {
                    val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                    visibleName?.let { result.add(it) }
                }
            }
        }
    }

    private fun collectPreludeVariantElements(project: com.intellij.openapi.project.Project, result: MutableList<ZenScriptNamedElement>, seen: MutableSet<String> = mutableSetOf()) {
        val preludeFile = project.getService(ZenScriptPreludeService::class.java)
            ?.getPreludeFile() ?: return
        for (child in preludeFile.children) {
            if (child is ZenScriptNamedElement) {
                val name = child.name ?: continue
                if (seen.add(name)) result.add(child)
            }
            if (child is ZenScriptExportFromStatement) {
                for (symbol in child.getImportSymbols()) {
                    val name = symbol.name ?: continue
                    if (seen.add(name)) result.add(symbol)
                }
            }
        }
    }

    fun collectProjectExportedSymbols(from: PsiFile, alreadySeen: Set<String>): List<ProjectSymbol> {
        val project = from.project
        val currentVFile = from.virtualFile ?: run {
            LOG.warn("ZenScript project completion: from.virtualFile is null")
            return emptyList()
        }
        val result = mutableListOf<ProjectSymbol>()
        val psiManager = PsiManager.getInstance(project)

        val roots = ProjectRootManager.getInstance(project).contentRoots
        LOG.warn("ZenScript project completion: contentRoots count = ${roots.size}, currentFile = ${currentVFile.path}")

        for (root in roots) {
            LOG.warn("ZenScript project completion: scanning root = ${root.path}")
            VfsUtilCore.iterateChildrenRecursively(root, null) { vFile ->
                if (!vFile.isDirectory && vFile.extension == "zs" && vFile != currentVFile) {
                    LOG.warn("ZenScript project completion: found .zs file = ${vFile.path}")
                    val relativePath = computeRelativePath(currentVFile, vFile)
                    if (relativePath != null) {
                        val psiFile = psiManager.findFile(vFile)
                        if (psiFile != null) {
                            for (child in psiFile.children) {
                                if (child is ZenScriptNamedElement) {
                                    val name = child.name ?: return@iterateChildrenRecursively true
                                    if (!alreadySeen.contains(name)) {
                                        result.add(ProjectSymbol(child, relativePath))
                                    }
                                }
                            }
                        } else {
                            LOG.warn("ZenScript project completion: psiManager.findFile returned null for ${vFile.path}")
                        }
                    } else {
                        LOG.warn("ZenScript project completion: computeRelativePath returned null for ${vFile.path}")
                    }
                }
                true
            }
        }
        LOG.warn("ZenScript project completion: total symbols collected = ${result.size}")
        return result
    }

    fun collectProjectZsFiles(from: VirtualFile, project: com.intellij.openapi.project.Project): List<Pair<VirtualFile, String>> {
        val result = mutableListOf<Pair<VirtualFile, String>>()
        val roots = ProjectRootManager.getInstance(project).contentRoots
        for (root in roots) {
            VfsUtilCore.iterateChildrenRecursively(root, null) { vFile ->
                if (!vFile.isDirectory && vFile.extension == "zs" && vFile != from) {
                    val rel = computeRelativePath(from, vFile)
                    if (rel != null) result.add(vFile to rel)
                }
                true
            }
        }
        return result
    }

    fun computeRelativePath(from: VirtualFile, to: VirtualFile): String? {
        val fromDir = from.parent ?: return null
        // Try direct relative path (to is under fromDir or its subdirectory)
        val direct = VfsUtilCore.getRelativePath(to, fromDir)
        if (direct != null) return "./$direct"
        // Walk up from fromDir to find a common ancestor
        var ancestor = fromDir.parent
        var upCount = 1
        while (ancestor != null) {
            val rel = VfsUtilCore.getRelativePath(to, ancestor)
            if (rel != null) {
                return "../".repeat(upCount) + rel
            }
            ancestor = ancestor.parent
            upCount++
        }
        return null
    }

    private fun collectImportedVariants(file: PsiFile?, result: MutableList<String>) {
        if (file == null) return
        for (child in file.children) {
            when (child) {
                is ZenScriptImportStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        visibleName?.let { result.add(it) }
                    }
                }
                is ZenScriptUseStatement -> {
                    for (symbol in child.getVariantSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        visibleName?.let { result.add(it) }
                    }
                }
                is ZenScriptExportFromStatement -> {
                    for (symbol in child.getImportSymbols()) {
                        val visibleName = symbol.getAlias() ?: symbol.getOriginalName()
                        visibleName?.let { result.add(it) }
                    }
                }
            }
        }
    }
}
