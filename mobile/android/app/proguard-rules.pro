# ---------------------------------------------------------------- Room / WorkManager
# Room genera en tiempo de compilacion una clase "<BaseDeDatos>_Impl" y la
# instancia por reflexion:
#     Room.getGeneratedImplementation() -> Class.forName("..._Impl").newInstance()
# R8 no ve esa llamada, asi que puede eliminar el constructor (o la clase) y
# Room falla al abrir la base de datos. WorkManager inicializa su WorkDatabase
# desde el InitializationProvider de androidx.startup. Ese fallo ocurre ANTES
# de que Flutter arranque: la app se abre y se cierra sola, sin nada en Dart.
# Por eso WorkManager 2.7.0 (que llega con google_mobile_ads) rompia el
# arranque en release.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep @androidx.room.Entity class *
-keep @androidx.room.Dao interface *
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>(...);
}
-dontwarn androidx.room.paging.**
