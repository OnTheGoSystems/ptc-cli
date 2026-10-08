<?php
function plugin_admin() {
    echo '<button>' . esc_html__( 'Save changes', 'plugin' ) . '</button>';
    printf( __( 'Hello %s', 'plugin' ), $name );
    echo _x( 'Post', 'noun', 'plugin' );
    echo _n( '%d item', '%d items', $n, 'plugin' );
}
