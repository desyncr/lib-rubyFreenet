require 'test/unit'

class URITest < Test::Unit::TestCase
  #def setup
  #end
  
  #def teardown
  #end
  
  def test_ksk_parsing
    uri_text = 'KSK@test-site-1'
    uri = Freenet::URI.new(uri_text)
    assert_equal(uri.uri, 'KSK@test-site-1')
    assert_equal(uri.type, 'KSK')
    assert_equal(uri.key, 'test-site-1')
    assert_raise(Freenet::URIMethodNotImplementedError) {uri.version = 1}
    assert_raise(Freenet::URIMethodNotImplementedError) {uri.name = 'my-cool-freesite'}
    assert_raise(Freenet::URIMethodNotImplementedError) {uri.path = 'my_path'}
    assert_nil(uri.version)
    assert_nil(uri.name)
    assert_nil(uri.path)
    
  end
  
  def test_chk_parsing
    uri_text = 'CHK@sdsdjfijvisjesjfsdjdskfsdlk,fdsknfdsfnoifhiw,dsskd/my-cool-pic.jpg'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri.uri, uri_text)
    assert_equal(uri.type, 'CHK')
    assert_equal(uri.key, 'sdsdjfijvisjesjfsdjdskfsdlk,fdsknfdsfnoifhiw,dsskd')
    assert_equal(uri.path, 'my-cool-pic.jpg')
    assert_raise(Freenet::URIMethodNotImplementedError) {uri.version = 1}
    assert_raise(Freenet::URIMethodNotImplementedError) {uri.name = 'my-cool-freesite'}
    assert_nil(uri.version)
    assert_nil(uri.name)
  end
  
  def test_usk_parsing
    uri_text = 'USK@adasdsadfegffpokp,olkpojreihauwehfw/coolsite/4/mystuff.html'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_text, uri.uri)
    assert_equal('USK', uri.type)
    assert_equal('adasdsadfegffpokp,olkpojreihauwehfw', uri.key)
    assert_equal('coolsite', uri.name)
    assert_equal(4, uri.version)
    assert_equal('mystuff.html', uri.path)
    
    uri_text = 'USK@adasdsadfegffpokp,olkpojreihauwehfw/coolsite/-1/'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_text, uri.uri)
    assert_equal(-1, uri.version)
    assert_equal("", uri.path)
  end
  
  def test_ssk_parsing
    uri_text = 'SSK@fsdmlkfmdsklf0344lk,lmfdsmvsskrngori3243/coolsite/page.html'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_text, uri.uri)
    assert_equal('SSK', uri.type)
    assert_equal('coolsite', uri.name)
    assert_equal('page.html', uri.path)
    assert_equal('fsdmlkfmdsklf0344lk,lmfdsmvsskrngori3243', uri.key)
    assert_nil(uri.version)
  end
  
  def test_ssk_version_parsing
    uri_text = 'SSK@fsdmlkfmdsklf0344lk,lmfdsmvsskrngori3243/coolsite-5/'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_text, uri.uri)
    assert_equal('SSK', uri.type)
    assert_equal('coolsite', uri.name)
    assert_equal('', uri.path)
    assert_equal('fsdmlkfmdsklf0344lk,lmfdsmvsskrngori3243', uri.key)
    assert_equal(5, uri.version)
  end
  
  def test_part_merge
    uri_text = 'SSK@1234,5678/coolsite/'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_text+'mypic.jpg', uri.merge('mypic.jpg'))
    assert_equal(uri_text+'things/meh.html', uri.merge('things/meh.html'))
    assert_equal('/stuff', uri.merge('/stuff'))
    assert_equal(uri_text, uri.merge('../'))
    assert_equal('CHK@123/thing.jpg', uri.merge('CHK@123/thing.jpg'))
    assert_equal('freenet:CHK@123/thing.jpg', uri.merge('freenet:CHK@123/thing.jpg'))
    uri.version = 3
    assert_equal('SSK@1234,5678/coolsite-3/', uri.uri)
    uri.key = '9876,54321'
    assert_equal('SSK@9876,54321/coolsite-3/', uri.uri)
  end
  
  def test_path_merge
    uri_base = 'SSK@1234,5678/coolsite/'
    uri_text = uri_base+'subdir/place.html'
    uri = Freenet::URI.new(uri_text.dup)
    assert_equal(uri_base, uri.merge('../'))
    assert_equal(uri_base+'index.html', uri.merge('../index.html'))
    assert_equal(uri_base+'index.html', uri.merge('../../index.html'))
    assert_equal(uri_base+'index.html', uri.merge('../../../index.html'))
    assert_equal(uri_base+'subdir/coolpic.jpg', uri.merge('coolpic.jpg'))
    assert_equal(uri_base+'subdir/coolpic.jpg', uri.merge('./coolpic.jpg'))
  end
end