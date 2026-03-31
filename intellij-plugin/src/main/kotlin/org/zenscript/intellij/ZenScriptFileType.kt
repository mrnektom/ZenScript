package org.zenscript.intellij

import com.intellij.openapi.fileTypes.LanguageFileType
import javax.swing.Icon

object ZenScriptFileType : LanguageFileType(ZenScriptLanguage) {
    override fun getName(): String = "ZenScript"
    override fun getDescription(): String = "ZenScript language file"
    override fun getDefaultExtension(): String = "zs"
    override fun getIcon(): Icon = ZenScriptIcons.FILE
}
