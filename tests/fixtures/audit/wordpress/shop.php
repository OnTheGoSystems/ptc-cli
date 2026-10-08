<?php
/**
 * Plugin Name: Shop
 * Text Domain: shop
 */
function shop_boot() { load_plugin_textdomain( 'shop', false, 'shop/languages' ); }
function shop_scripts() { wp_set_script_translations( 'shop-cart', 'shop' ); wp_set_script_translations( 'shop-admin', 'shop' ); }
function shop_header( $site, $n, $domain ) {
	echo 'Welcome to our shop';
	esc_html_e( 'Checkout', 'shop' );
	echo __( 'Hello', 'shop' ) . ' ' . $site;
	echo __( 'Settings', $domain );
	echo __( 'Order ' . $n, 'shop' );
	echo $n == 1 ? __( 'item', 'shop' ) : __( 'items', 'shop' );
	echo date( 'Y-m-d' );
	echo date_i18n( get_option( 'date_format' ) );
	echo '<button>' . esc_html__( 'Save changes', 'shop' ) . '</button>';
	echo '<div class="notice notice-warning"><p>' . sprintf( esc_html__( 'Note: The <em>Shop</em> plugin is active on: %s. Many of the settings below do not apply.', 'shop' ), $site ) . '</p></div>';
	?>
	<p>Free shipping on all orders</p>
	<p><?php esc_html_e( 'Thanks for your order', 'shop' ); ?></p>
	<?php
}
