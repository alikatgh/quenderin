package ai.quenderin.core

import java.io.*
import java.nio.file.Files
import java.util.Base64
fun main(args:Array<String>) {
 val root=if(args.isNotEmpty()) File(args[0]) else Files.createTempDirectory("vision-fixture-").toFile();check(root.mkdirs()||root.isDirectory)
 try {
  val model=VisionModels.all.first()
  check(runCatching { VisionModelInstaller.checkResources(model,model.minimumMemoryBytes-1,Long.MAX_VALUE) }.isFailure)
  check(runCatching { VisionModelInstaller.checkResources(model,model.minimumMemoryBytes,67_108_863) }.isFailure)
  val models=File(root,"models");val installer=VisionModelInstaller(models)
  check(runCatching { installer.install(model,0,Long.MAX_VALUE){} }.isFailure);check(!models.exists())
  val png=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/hj0AAAAASUVORK5CYII=")
  val source=File(root,"original.png");source.writeBytes(png)
  val selected=source.inputStream().use { VisionSelectedImage.copy(it,File(root,"selected")) }
  check(selected.readBytes().contentEquals(png)&&source.readBytes().contentEquals(png))
  val wide=png.copyOf();wide[16]=0;wide[17]=0;wide[18]=0x20;wide[19]=0
  check(runCatching { VisionSelectedImage.copy(ByteArrayInputStream(wide),File(root,"rejected")) }.isFailure)
  check(File(root,"rejected").listFiles()!!.isEmpty())
  val duplicate=png.copyOfRange(0,33)+png.copyOfRange(8,33)+png.copyOfRange(33,png.size)
  check(runCatching { VisionSelectedImage.copy(ByteArrayInputStream(duplicate),File(root,"duplicate")) }.isFailure)
  val link=File(root,"alias");Files.createSymbolicLink(link.toPath(),source.toPath())
  check(runCatching { VisionSelectedImage.validate(link) }.isFailure);check(source.readBytes().contentEquals(png))
  println("Kotlin Vision resource/still-image bounds/copy fixtures passed; originals preserved")
 } finally { root.deleteRecursively() }
}
